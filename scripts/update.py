#!/usr/bin/env python3
from pathlib import Path
from sqlite3 import Connection as DBConnection
from tempfile import gettempdir
from urllib import request
import csv
import shutil
import subprocess
import tarfile

# Check dependencies.
subprocess.check_call(['cargo', '--version'], stdout=subprocess.DEVNULL)

CACHE_CRATE_CALC_TIME = '-1 month'
CACHE_CRATE_CNT = 256
CACHE_PROJECT_ROOT = Path(__file__).parent.parent / 'cache'
CACHE_TOML_FILE = CACHE_PROJECT_ROOT / 'Cargo.toml'

DB_URL = 'https://static.crates.io/db-dump.tar.gz'
DB_DIR = Path(gettempdir()) / 'cratesio-db-dump'
DB_PATH = DB_DIR / 'db.sqlite'
DB_INIT = r'''
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
DB_INSERT_SQLS = {
    'crates': 'insert into crates values (?,?,?,?,?,?,?,?,?,?,?)',
    'versions': 'insert into versions values (?,?,?,?,?,?,?,?,?,?,?)',
    'version_downloads': 'insert into version_downloads values (?,?,?)',
}

def openDatabase() -> DBConnection:
    return DBConnection(str(DB_PATH))

def initDatabase() -> DBConnection:
    DB_DIR.mkdir(exist_ok=True)
    mtime_file = DB_DIR / 'mtime.txt'
    last_mtime = mtime_file.read_text() if mtime_file.is_file() else None

    print('Checking database mtime')
    with request.urlopen(DB_URL) as resp:
        assert resp.status == 200, f'HTTP failure {resp.status}'
        mtime: str = resp.headers['last-modified']
        if mtime == last_mtime and DB_PATH.exists():
            print(f'Database is up-to-date at {mtime}')
            return openDatabase()

        print(f'Fetching database at {mtime}')
        for child in DB_DIR.iterdir():
            if child.is_dir():
                shutil.rmtree(str(child))
        with tarfile.open(fileobj=resp, mode='r|gz') as tar:
            tar.extractall(path=DB_DIR)

    print('Importing data')
    DB_PATH.unlink()
    conn = openDatabase()
    conn.executescript(DB_INIT)
    csv.field_size_limit(2 ** 30) # There are large fields.
    for tbl_name, insert_sql in DB_INSERT_SQLS.items():
        files = list(DB_DIR.glob(f'*/data/{tbl_name}.csv'))
        assert len(files) == 1
        with open(files[0], 'r') as fin:
            rdr = csv.reader(fin, lineterminator='\n')
            next(rdr) # Skip the header.
            conn.executemany(insert_sql, rdr)

    conn.commit()
    mtime_file.write_text(mtime)
    print('Database initialized')
    return conn

def updateCratesList(conn: DBConnection) -> None:
    cursor = conn.cursor()
    cursor.execute('''
        select crates.name, versions.num
        from version_downloads
        join versions on versions.id == version_id
        join crates on crates.id == versions.crate_id
        where version_downloads.date > date('now', ?)
        group by version_id
        order by sum(version_downloads.downloads) desc
        limit ?;
    ''', [CACHE_CRATE_CALC_TIME, CACHE_CRATE_CNT])

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

    crates: list[tuple[str, Vers]] = [(row[0], Vers(row[1])) for row in cursor]
    crates.sort()

    print('======== Start of top crates')
    for name, vers in crates:
        print(name, vers)
    print('======== End of top crates')

    deps: list[tuple[str, list[Vers]]] = []
    for name, vers in crates:
        if deps and deps[-1][0] == name:
            if vers.compatible_with(deps[-1][1][-1]):
                continue
            deps[-1][1].append(vers)
        else:
            deps.append((name, [vers]))

    oldContent = CACHE_TOML_FILE.read_text()
    with open(CACHE_TOML_FILE, 'w') as fout:
        for line in oldContent.splitlines():
            fout.write(line + '\n')
            if line == '[dependencies]':
                break
        for name, verss in deps:
            fout.write(f'{name} = "{verss[0]}"\n')
            for i, v in enumerate(verss[1:], 2):
                fout.write(f'{name}-{i} = {{ package = "{name}", version = "{v}" }}\n')

    print('Updating lock file')
    subprocess.check_call(['cargo', 'update'], cwd=CACHE_PROJECT_ROOT)
    print('Verifying crates')
    subprocess.check_call(
        ['cargo', 'metadata', '--format-version=1'],
        cwd=CACHE_PROJECT_ROOT,
        stdout=subprocess.DEVNULL,
    )

def main() -> None:
    with initDatabase() as conn:
        updateCratesList(conn)

main()
