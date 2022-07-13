#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p cargo "python3.withPackages (ps: with ps; [ aiohttp toml ])"
from io import BytesIO
from pathlib import Path
from typing import Callable, Optional
from typing_extensions import Self
from urllib import request
import aiohttp
import argparse
import asyncio
import csv
import os
import re
import sqlite3
import subprocess
import sys
import tarfile
import toml

# Check dependencies.
subprocess.check_call(['cargo', '--version'], stdout=subprocess.DEVNULL)

# CRATE_TARBALL_URL = 'https://crates.io/api/v1/crates/{name}/{version}/download' # -> 302
CRATE_TARBALL_URL = 'https://static.crates.io/crates/{name}/{name}-{version}.crate' # -> 200 application/gzip

POPULAR_CRATES_MANIFEST_PATH = Path(__file__).parent.parent / 'cache' / 'Cargo.toml'
PROC_MACRO_LIST_PATH = Path(__file__).parent.parent / 'crates-io-override' / 'proc-macro.nix'

CACHE_DIR = Path(os.environ.get('XDG_CACHE_HOME') or (Path.home() / '.cache')) / 'cratesio'
CRATES_TOML_DIR = CACHE_DIR / 'toml'

def noisily(*args) -> None:
    print(*args, file=sys.stderr)

class CratesioDB(sqlite3.Connection):
    DB_URL = 'https://static.crates.io/db-dump.tar.gz'

    DB_DIR = CACHE_DIR
    DB_PATH = DB_DIR / 'db.sqlite'
    MTIME_PATH = DB_DIR / 'mtime.txt'

    INIT_SQL = r'''
        PRAGMA journal_mode = off;
        PRAGMA cache_size = -{cache_kb};

        CREATE TABLE IF NOT EXISTS crates (
            id INTEGER NOT NULL PRIMARY KEY,
            name TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            downloads INTEGER NOT NULL
        ) STRICT;
        CREATE TABLE IF NOT EXISTS versions (
            id INTEGER NOT NULL PRIMARY KEY,
            crate_id INTEGER NOT NULL,
            num TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            created_at TEXT NOT NULL,
            downloads INTEGER NOT NULL,
            features TEXT NOT NULL,
            yanked INTEGER NOT NULL,
            license TEXT
        ) STRICT;
        CREATE TABLE IF NOT EXISTS version_downloads (
            version_id INTEGER NOT NULL,
            downloads INTEGER NOT NULL,
            date TEXT NOT NULL,
            PRIMARY KEY (version_id, date)
        ) STRICT, WITHOUT ROWID;
    '''

    INIT_INDEX_SQL = r'''
        CREATE INDEX IF NOT EXISTS versions_ix_crate_to_version ON versions
            (crate_id, id);
        ANALYZE;
    '''

    INSERTERS: dict[str, tuple[str, Callable[[dict[str, str]], tuple]]] = {
        'crates.csv': (
            'INSERT INTO crates VALUES (?,?,?,?,?)',
            lambda row: (
                int(row['id']),
                row['name'],
                row['created_at'],
                row['updated_at'],
                int(row['downloads']),
            ),
        ),
        'versions.csv': (
            'INSERT INTO versions VALUES (?,?,?,?,?,?,?,?,?)',
            lambda row: (
                int(row['id']),
                int(row['crate_id']),
                row['num'],
                row['updated_at'],
                row['created_at'],
                int(row['downloads']),
                row['features'],
                row['yanked'] == 't',
                row['license'],
            ),
        ),
        'version_downloads.csv': (
            'INSERT INTO version_downloads VALUES (?,?,?)',
            lambda row: (
                int(row['version_id']),
                int(row['downloads']),
                row['date'],
            )
        ),
    }

    def __init__(self, *, check: bool=True, cache_mb: int=1024) -> None:
        assert not check or self.MTIME_PATH.exists(), 'Database not initialized, please run `sync` subcommand'
        super().__init__(str(self.DB_PATH))
        self.executescript(self.INIT_SQL.format(cache_kb=cache_mb * 1024))

    @classmethod
    def sync(cls, *, cache_mb: int=1024) -> None:
        cls.DB_DIR.mkdir(exist_ok=True)
        last_mtime = cls.MTIME_PATH.read_text() if cls.MTIME_PATH.exists() else None

        noisily('Synchronizing database')
        with request.urlopen(cls.DB_URL) as resp:
            assert resp.status == 200, f'HTTP failure {resp.status}'
            mtime: str = resp.headers['last-modified']
            if mtime == last_mtime:
                noisily(f'Database is up-to-date at {mtime}')
                return

            noisily(f'Fetching and importing database dump at {mtime}, previous at {last_mtime}')
            cls.DB_PATH.unlink(missing_ok=True)
            db = CratesioDB(check=False, cache_mb=cache_mb)

            csv.field_size_limit(2 ** 30) # There are large fields.
            with tarfile.open(fileobj=resp, mode='r|gz') as tar:
                for member in tar:
                    name = member.path.split('/')[-1]
                    if name in cls.INSERTERS:
                        sql, preprocessor = cls.INSERTERS[name]
                        fileobj = tar.extractfile(member)
                        assert fileobj is not None
                        rdr = csv.DictReader(map(bytes.decode, fileobj))
                        db.executemany(sql, map(preprocessor, rdr))

            noisily(f'Creating indices')
            db.executescript(cls.INIT_INDEX_SQL)
            db.commit()
            db.close()

            cls.MTIME_PATH.write_text(mtime)
            noisily('Database initialized')

def update_popular_crates(db: CratesioDB, *, time: str, limit: int) -> None:
    class VersMajor(tuple):
        RE_SEMVER = re.compile(r'^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$')

        def __new__(cls: type[Self], s: str) -> Self:
            m = cls.RE_SEMVER.match(s)
            assert m is not None, f'Invalid semver: {s}'
            maj, min, pat = map(int, (m[1], m[2], m[3]))
            vers = (maj,) if maj else (maj, min) if min else (maj, min, pat)
            return super().__new__(cls, vers)

        def __str__(self) -> str:
            return '.'.join(map(str, self))

        # Reversed.
        def __lt__(self, rhs: Self) -> bool:
            return super().__gt__(rhs)

    noisily('Querying database')
    cursor = db.cursor()
    cursor.execute('''
        SELECT crates.name, versions.num
        FROM version_downloads
        JOIN versions ON versions.id == version_id
        JOIN crates ON crates.id == versions.crate_id
        WHERE version_downloads.date > DATE('now', ?)
        GROUP BY version_id
        ORDER BY SUM(version_downloads.downloads) DESC
    ''', (time,))

    crates_set: set[tuple[str, VersMajor]] = set()
    for row in cursor:
        crates_set.add((str(row[0]), VersMajor(row[1])))
        if len(crates_set) == limit:
            break

    crates = sorted(crates_set)

    noisily('======== Start of top crates')
    for name, vers in crates:
        noisily(name, vers)
    noisily('======== End of top crates')

    out_path = POPULAR_CRATES_MANIFEST_PATH
    tmp_path = out_path.with_suffix('.tmp')
    with out_path.open('r') as fin, tmp_path.open('w') as fout:
        for line in fin:
            fout.write(line)
            if line.startswith('[dependencies]'):
                break

        last_name: Optional[str] = None
        crate_idx = 1
        for name, vers in crates:
            if last_name != name:
                crate_idx = 1
                fout.write(f'{name} = "{vers}"\n')
            else:
                crate_idx += 1
                fout.write(f'{name}-{crate_idx} = {{ package = "{name}", version = "{vers}" }}\n')
            last_name = name
    tmp_path.replace(out_path)

    noisily('Updating lock file')
    subprocess.check_call(['cargo', 'update', f'--manifest-path={out_path}'])

    noisily('Verifying crates metadata')
    subprocess.check_call(
        ['cargo', 'metadata', f'--manifest-path={out_path}', '--format-version=1'],
        stdout=subprocess.DEVNULL,
    )

def list_popular_crates(db: CratesioDB, *, time: str, pat: Optional[str]) -> None:
    noisily('Querying database')
    cursor = db.cursor()
    cursor.execute('''
        SELECT crates.name, SUM(version_downloads.downloads) AS crate_downloads
        FROM crates
        JOIN versions ON versions.crate_id == crates.id
        JOIN version_downloads ON version_downloads.version_id == versions.id
        WHERE crates.name LIKE ? AND version_downloads.date > DATE('now', ?)
        GROUP BY versions.crate_id
        ORDER BY crate_downloads DESC
    ''', (pat if pat is not None else '%', time))
    try:
        for row in cursor:
            print(row[0], row[1])
    except BrokenPipeError as _:
        # Suppress backtrace.
        exit(1)

def update_proc_macro_crates(db: CratesioDB, *, concurrency: int) -> None:
    CRATES_TOML_DIR.mkdir(exist_ok=True)

    noisily('Querying database')
    cursor = db.cursor()
    cursor.execute('''
        SELECT crates.name, versions.num AS max_vers, MAX(versions.created_at)
        FROM versions
        JOIN crates ON crates.id == crate_id
        WHERE NOT yanked
        GROUP BY crate_id
        ORDER BY crates.name ASC
    ''')

    RE_ITEMS = re.compile(r'"([^"]*)"', re.S)
    proc_macro_crates: set[str] = set(m[1] for m in RE_ITEMS.finditer(PROC_MACRO_LIST_PATH.read_text()))

    async def load_or_fetch(sema: asyncio.Semaphore, name: str, version: str) -> None:
        try:
            out_path = CRATES_TOML_DIR / f'{name}.toml'
            if not out_path.exists():
                noisily(f'GET {name} {version}')
                url = CRATE_TARBALL_URL.format(name=name, version=version)
                async with aiohttp.request(method='GET', url=url) as resp:
                    resp.raise_for_status()
                    data = await resp.read()

                with tarfile.open(mode='r|gz', fileobj=BytesIO(data)) as tar:
                    for member in tar:
                        segments = member.path.split('/')
                        if len(segments) == 2 and segments[-1] == 'Cargo.toml':
                            f = tar.extractfile(member)
                            assert f is not None
                            tmp_path = out_path.with_suffix('.tmp')
                            tmp_path.write_bytes(f.read())
                            tmp_path.replace(out_path)
                            break
                    else:
                        assert False, 'No Cargo.toml found'
        except (aiohttp.ClientError, tarfile.TarError, UnicodeDecodeError, AssertionError) as exc:
            print(f'For {name} {version}: {exc}', file=sys.stderr)
            return
        finally:
            sema.release()

        try:
            # Must exist if we are here.
            with open(out_path, 'r') as fin:
                manifest = toml.load(fin)
            lib = manifest.get('lib', {})
            if isinstance(lib, dict) and lib.get('proc-macro', False) is True:
                proc_macro_crates.add(name)
        except (UnicodeDecodeError, toml.TomlDecodeError) as exc:
            print(f'For cached {name}: {exc}', file=sys.stderr)
            return

    async def proc() -> None:
        sema = asyncio.Semaphore(concurrency)
        for row in cursor:
            name: str = row[0]
            vers: str = row[1]
            await sema.acquire()
            asyncio.create_task(load_or_fetch(sema, name, vers))

        # Wait until all done.
        for _ in range(concurrency):
            await sema.acquire()

    noisily('Retrieving metadata')
    asyncio.run(proc())

    noisily(f'Writing to {PROC_MACRO_LIST_PATH}')
    with PROC_MACRO_LIST_PATH.open('w') as fout:
        fout.write('[\n')
        for name in sorted(proc_macro_crates):
            assert '"' not in name
            fout.write(f'"{name}"\n')
        fout.write(']\n')

def main() -> None:
    parser = argparse.ArgumentParser(description='Metadata updater and utilities using crates.io database dump')
    parser.add_argument('--cache-mb', type=int, required=False, default=1024, help='Sqlite cache size in MiB')
    subparser = parser.add_subparsers(required=True)

    p = subparser.add_parser('sync', help='Synchronize or initialize the database')
    p.set_defaults(sync=True)

    p = subparser.add_parser('update-popular-crates', help='Update popular crates cache')
    p.add_argument('--limit', type=int, required=False, default=256, help='Number of top crates to cache')
    p.add_argument('--time', type=str, default='-90 days', help='Time period to count recent downloads')
    p.set_defaults(fn=update_popular_crates)

    p = subparser.add_parser('list-popular-crates', help='Print popular crates with download counts in a given period')
    p.add_argument('--time', type=str, default='-90 days', help='Time period to count recent downloads')
    p.add_argument('--pat', type=str, default=None, help='Crate name pattern to filter for SQL "LIKE"')
    p.set_defaults(fn=list_popular_crates)

    p = subparser.add_parser('update-proc-macro-crates', help='Update the list of proc-macro crates')
    p.add_argument('--concurrency', type=int, default=16, help='Connection concurrency')
    p.set_defaults(fn=update_proc_macro_crates)

    args = parser.parse_args()
    if 'sync' in args:
        CratesioDB.sync(cache_mb=args.cache_mb)
    else:
        subargs = vars(args)
        with CratesioDB(cache_mb=subargs.pop('cache_mb')) as db:
            subargs.pop('fn')(db, **subargs)

main()
