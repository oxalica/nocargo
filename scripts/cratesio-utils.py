#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p cargo "python3.withPackages (ps: with ps; [ aiohttp toml ])"
from io import BytesIO
from pathlib import Path
from typing import Optional
from urllib import request
import aiohttp
import argparse
import asyncio
import csv
import re
import shutil
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

# nix-shell would mess up with `TMPDIR`.
TMP_DB_DIR = Path('/tmp/cratesio-db-dump')
TMP_CRATES_TOML_DIR = Path('/tmp/cratesio-toml')

def noisily(*args) -> None:
    print(*args, file=sys.stderr)

class CratesioDB(sqlite3.Connection):
    DB_URL = 'https://static.crates.io/db-dump.tar.gz'

    DB_DIR = Path('/tmp/cratesio-db-dump') # nix-shell would mess up with `TMPDIR`.
    DB_PATH = DB_DIR / 'db.sqlite'
    MTIME_PATH = DB_DIR / 'mtime.txt'

    INIT_SQL = r'''
        pragma journal_mode=off;
        create table crates(
            created_at text,
            description text,
            documentation text,
            downloads text,
            homepage text,
            id int not null primary key,
            max_update_size int,
            name text,
            readme text,
            repository text,
            updated_at text
        );
        create table versions(
            crate_id int not null,
            crate_size int,
            created_at text,
            downloads int,
            features text,
            id int not null primary key,
            license text,
            num text,
            published_by text,
            updated_at text,
            yanked text
        );
        create table version_downloads(
            date text,
            downloads int,
            version_id int not null
        );
    '''
    INSERT_SQLS = {
        'crates': 'insert into crates values (?,?,?,?,?,?,?,?,?,?,?)',
        'versions': 'insert into versions values (?,?,?,?,?,?,?,?,?,?,?)',
        'version_downloads': 'insert into version_downloads values (?,?,?)',
    }

    def __init__(self, sync: bool=False) -> None:
        if sync or not self.DB_PATH.exists():
            self._sync_and_open()
        else:
            self._open()

    def _open(self) -> None:
        super().__init__(str(self.DB_PATH))

    def _sync_and_open(self) -> None:
        self.DB_DIR.mkdir(exist_ok=True)
        last_mtime = self.MTIME_PATH.read_text() if self.MTIME_PATH.is_file() else None

        noisily('Syncing database')
        with request.urlopen(self.DB_URL) as resp:
            assert resp.status == 200, f'HTTP failure {resp.status}'
            mtime: str = resp.headers['last-modified']
            if mtime == last_mtime and self.DB_PATH.exists():
                noisily(f'Database is up-to-date at {mtime}')
                self._open()
                return

            noisily(f'Fetching database dump {mtime}, previously {last_mtime}')
            for child in self.DB_DIR.iterdir():
                if child.is_dir():
                    shutil.rmtree(str(child))
            with tarfile.open(fileobj=resp, mode='r|gz') as tar:
                tar.extractall(path=self.DB_DIR)

        noisily('Importing data')
        self.DB_PATH.unlink(missing_ok=True)

        self._open()
        self.executescript(self.INIT_SQL)
        csv.field_size_limit(2 ** 30) # There are large fields.
        for tbl_name, insert_sql in self.INSERT_SQLS.items():
            files = list(self.DB_DIR.glob(f'*/data/{tbl_name}.csv'))
            assert len(files) == 1
            with open(files[0], 'r') as fin:
                rdr = csv.reader(fin, lineterminator='\n')
                next(rdr) # Skip the header.
                self.executemany(insert_sql, rdr)

        self.commit()
        self.MTIME_PATH.write_text(mtime)
        noisily('Database initialized')

def update_popular_crates(db: CratesioDB, *, time: str, limit: Optional[int] = None) -> None:
    class Vers(object):
        def __init__(self, s: str) -> None:
            self.maj, self.min, self.pat = map(int, s.split('.'))

        def __str__(self) -> str:
            return f'{self.maj}.{self.min}.{self.pat}'

        def compatible_with(self, rhs) -> bool:
            return self.maj == rhs.maj if self.maj != 0 else self.min == rhs.min if self.min != 0 else self.pat != self.pat

        # Reversed.
        def __lt__(self, rhs) -> bool:
            return (self.maj, self.min, self.pat) > (rhs.maj, rhs.min, rhs.pat)

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
        LIMIT ?
    ''', [time, limit if limit is not None else -1])
    crates = [(str(row[0]), Vers(row[1])) for row in cursor]
    crates.sort()

    noisily('======== Start of top crates')
    for name, vers in crates:
        noisily(name, vers)
    noisily('======== End of top crates')

    deps: list[tuple[str, list[Vers]]] = []
    for name, vers in crates:
        if deps and deps[-1][0] == name:
            if vers.compatible_with(deps[-1][1][-1]):
                continue
            deps[-1][1].append(vers)
        else:
            deps.append((name, [vers]))

    out_path = POPULAR_CRATES_MANIFEST_PATH
    tmp_path = out_path.with_suffix('.tmp')
    with out_path.open('r') as fin, tmp_path.open('w') as fout:
        for line in fin:
            fout.write(line + '\n')
            if line == '[dependencies]':
                break
        for name, verss in deps:
            fout.write(f'{name} = "{verss[0]}"\n')
            for i, v in enumerate(verss[1:], 2):
                fout.write(f'{name}-{i} = {{ package = "{name}", version = "{v}" }}\n')
    tmp_path.replace(out_path)

    noisily('Updating lock file')
    subprocess.check_call(['cargo', 'update', f'--manifest-path={out_path}'])

    noisily('Verifying crates metadata')
    subprocess.check_call(
        ['cargo', 'metadata', f'--manifest-path={out_path}', '--format-version=1'],
        stdout=subprocess.DEVNULL,
    )

def print_popular_crates(db: CratesioDB, *, time: str, limit: Optional[int], pat: Optional[str]) -> None:
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
        LIMIT ?
    ''', [pat if pat is not None else '%', time, limit if limit is not None else -1])
    try:
        for row in cursor:
            print(row[0], row[1])
    except BrokenPipeError as _:
        # Suppress backtrace.
        exit(1)

def update_proc_macro_crates(db: CratesioDB, *, concurrency: int) -> None:
    TMP_CRATES_TOML_DIR.mkdir(exist_ok=True)

    noisily('Querying database')
    cursor = db.cursor()
    cursor.execute('''
        SELECT crates.name, versions.num AS max_vers, MAX(versions.created_at)
        FROM versions
        JOIN crates ON crates.id == crate_id
        WHERE yanked == 'f'
        GROUP BY crate_id
        ORDER BY crates.name asc
    ''')

    RE_ITEMS = re.compile(r'"([^"]*)"', re.S)
    proc_macro_crates: set[str] = set(m[1] for m in RE_ITEMS.finditer(PROC_MACRO_LIST_PATH.read_text()))

    async def load_or_fetch(sema: asyncio.Semaphore, name: str, version: str) -> None:
        try:
            out_path = TMP_CRATES_TOML_DIR / f'{name}.toml'
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
    parser.add_argument('--sync', action='store_true', help='Synchronizing the database even if it exists')
    subparser = parser.add_subparsers(required=True)

    p = subparser.add_parser('update-popular-crates')
    p.add_argument('--limit', type=int, required=False, default=None, help='Number of top crates')
    p.add_argument('--time', type=str, default='-90 days', help='Time period to count recent downloads')
    p.set_defaults(fn=update_popular_crates)

    p = subparser.add_parser('print-popular-crates')
    p.add_argument('--limit', type=int, required=False, help='Number of top crates')
    p.add_argument('--time', type=str, default='-90 days', help='Time period to count recent downloads')
    p.add_argument('--pat', type=str, default=None, help='Crate name pattern to filter for SQL "LIKE"')
    p.set_defaults(fn=print_popular_crates)

    p = subparser.add_parser('update-proc-macro-crates')
    p.add_argument('--concurrency', type=int, default=16, help='Connection concurrency')
    p.set_defaults(fn=update_proc_macro_crates)

    args = parser.parse_args()
    fn, sync = args.fn, args.sync

    subargs = vars(args)
    del subargs['sync'], subargs['fn']

    with CratesioDB(sync=sync) as db:
        fn(db, **subargs)

main()
