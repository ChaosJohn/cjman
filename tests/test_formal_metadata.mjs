import assert from 'node:assert/strict';
import {
  cpSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

import {
  MetadataError,
  discoverVersionBundleUrl,
  mergeCatalogRows,
  parseFormalReleaseBundle,
  parseSdkFilename,
  renderCatalogTsv,
  renderReleaseTsv,
  updateFormalRelease,
  validateMetadataDirectory,
  validateReleaseRows,
} from '../scripts/update-formal-release.mjs';

const TEST_DIR = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = resolve(TEST_DIR, '..');
const FIXTURE_PATH = join(
  TEST_DIR,
  'fixtures',
  'formal-release',
  'version.fixture.js',
);
const FIXTURE = readFileSync(FIXTURE_PATH, 'utf8').replaceAll('\r\n', '\n');
const REPOSITORY_METADATA_DIR = join(PROJECT_ROOT, 'metadata', 'v2');
const REPOSITORY_BASELINE = validateMetadataDirectory(
  REPOSITORY_METADATA_DIR,
);

test('parses legacy SDK names and excludes the legacy VSCode plugin', () => {
  const release = parseFormalReleaseBundle(FIXTURE, '0.53.99');
  assert.deepEqual(release.catalog, {
    version: '0.53.99',
    channel: 'STS',
    display_name: 'Cangjie 0.53.99',
    published_at: '2024-10-24',
  });
  assert.equal(release.rows.length, 3);
  assert.deepEqual(
    release.rows.map((row) => [
      row.host_os,
      row.host_arch,
      row.target_os,
      row.target_arch,
      row.format,
    ]),
    [
      ['windows', 'x64', 'native', 'x64', 'zip'],
      ['mac', 'aarch64', 'native', 'aarch64', 'tar.gz'],
      ['linux', 'x64', 'native', 'x64', 'tar.gz'],
    ],
  );
  assert.equal(release.rows[0].sha256, 'A'.repeat(64));
});

test('parses modern native, generic target, and explicit target arch names', () => {
  const release = parseFormalReleaseBundle(FIXTURE, '2.0.0-beta.1');
  assert.equal(release.catalog.channel, 'LTS');
  assert.equal(release.catalog.published_at, '2027-01-02');
  assert.equal(release.rows.length, 4);
  assert.deepEqual(
    release.rows.map((row) => [
      row.host_os,
      row.host_arch,
      row.target_os,
      row.target_arch,
      row.format,
    ]),
    [
      ['windows', 'x64', 'native', 'x64', 'exe'],
      ['windows', 'x64', 'native', 'x64', 'zip'],
      ['mac', 'aarch64', 'ios', 'any', 'tar.gz'],
      ['linux', 'x64', 'android', 'arm32', 'tar.gz'],
    ],
  );
  assert.match(
    renderReleaseTsv(release.rows),
    /fileName=cangjie-sdk-windows-x64-2\.0\.0-beta\.1\.zip&objectKey=/,
  );
});

test('asset parsing does not depend on name being the first property', () => {
  const reordered = FIXTURE.replace(
    /name: "(cangjie-sdk-windows-x64-2\.0\.0-beta\.1\.exe)",\n\s+url: "([^"]+)"/,
    'url: "$2",\n                        name: "$1"',
  );
  assert.notEqual(reordered, FIXTURE);
  assert.equal(
    parseFormalReleaseBundle(reordered, '2.0.0-beta.1').rows.length,
    4,
  );
});

test('every leaf in an SDK platform group must use a recognized SDK filename', () => {
  const marker = `                        size: "373.96MB"
                      }
                    ]`;
  const replacement = `                        size: "373.96MB"
                      },
                      {
                        name: "cangjie-toolchain-windows-x64-2.0.0-beta.1.zip",
                        url: "/v1/files/auth/downLoad?nsId=142267&fileName=cangjie-toolchain-windows-x64-2.0.0-beta.1.zip&objectKey=unknownWindows001",
                        version: "2.0.0-beta.1",
                        time: "2027-01-02",
                        sha: "5555555555555555555555555555555555555555555555555555555555555555",
                        size: "373.96MB"
                      }
                    ]`;
  const unknownAsset = FIXTURE.replace(marker, replacement);
  assert.notEqual(unknownAsset, FIXTURE);
  assert.throws(
    () => parseFormalReleaseBundle(unknownAsset, '2.0.0-beta.1'),
    /Unrecognized SDK filename/,
  );
});

test('all three SDK platform groups must exist and be nonempty', () => {
  const renamedGroup = FIXTURE.replace(
    `                    name: "Mac",
                    list: [
                      {
                        name: "cangjie-sdk-mac-aarch64-ios-2.0.0-beta.1.tar.gz"`,
    `                    name: "macOS",
                    list: [
                      {
                        name: "cangjie-sdk-mac-aarch64-ios-2.0.0-beta.1.tar.gz"`,
  );
  assert.notEqual(renamedGroup, FIXTURE);
  assert.throws(
    () => parseFormalReleaseBundle(renamedGroup, '2.0.0-beta.1'),
    /unsupported SDK platform group: macOS/,
  );

  const macAsset = `                      {
                        name: "cangjie-sdk-mac-aarch64-ios-2.0.0-beta.1.tar.gz",
                        url: "/v1/files/auth/downLoad?nsId=142267&fileName=cangjie-sdk-mac-aarch64-ios-2.0.0-beta.1.tar.gz&objectKey=modernMacIos0001",
                        version: "2.0.0-beta.1",
                        time: "2027-01-02",
                        sha: "3333333333333333333333333333333333333333333333333333333333333333",
                        size: "350.3MB"
                      }`;
  const macGroup = `                  {
                    name: "Mac",
                    list: [
${macAsset}
                    ]
                  },
`;
  const missingGroup = FIXTURE.replace(macGroup, '');
  assert.notEqual(missingGroup, FIXTURE);
  assert.throws(
    () => parseFormalReleaseBundle(missingGroup, '2.0.0-beta.1'),
    /missing the Mac SDK group/,
  );

  const emptyGroup = FIXTURE.replace(macAsset, '');
  assert.notEqual(emptyGroup, FIXTURE);
  assert.throws(
    () => parseFormalReleaseBundle(emptyGroup, '2.0.0-beta.1'),
    /empty Mac SDK group/,
  );
});

test('an additional SDK platform group must not be silently ignored', () => {
  const linuxGroupStart = `                  {
                    name: "Linux",
                    list: [
                      {
                        name: "cangjie-sdk-linux-x64-android-arm32-2.0.0-beta.1.tar.gz"`;
  const additionalGroup = `                  {
                    name: "FreeBSD",
                    list: [
                      {
                        name: "cangjie-sdk-freebsd-x64-2.0.0-beta.1.tar.gz",
                        url: "/v1/files/auth/downLoad?nsId=142267&fileName=cangjie-sdk-freebsd-x64-2.0.0-beta.1.tar.gz&objectKey=unknownFreebsd001",
                        version: "2.0.0-beta.1",
                        time: "2027-01-02",
                        sha: "6666666666666666666666666666666666666666666666666666666666666666",
                        size: "300.0MB"
                      }
                    ]
                  },
${linuxGroupStart}`;
  const unknownGroup = FIXTURE.replace(linuxGroupStart, additionalGroup);
  assert.notEqual(unknownGroup, FIXTURE);
  assert.throws(
    () => parseFormalReleaseBundle(unknownGroup, '2.0.0-beta.1'),
    /unsupported SDK platform group: FreeBSD/,
  );
});

test('an SDK leaf must match its containing platform group', () => {
  const wrongGroup = FIXTURE.replaceAll(
    'cangjie-sdk-mac-aarch64-ios-2.0.0-beta.1.tar.gz',
    'cangjie-sdk-linux-aarch64-2.0.0-beta.1.tar.gz',
  );
  assert.notEqual(wrongGroup, FIXTURE);
  assert.throws(
    () => parseFormalReleaseBundle(wrongGroup, '2.0.0-beta.1'),
    /listed under Mac, but its filename identifies host linux/,
  );
});

test('page and bundle SDK filename sets must match exactly', () => {
  const release = parseFormalReleaseBundle(FIXTURE, '2.0.0-beta.1');
  const pageHtml = [
    'Cangjie 2.0.0-beta.1',
    '2027/01/02',
    ...release.rows.flatMap((row) => [row.filename, row.size]),
    'cangjie-sdk-linux-x64-ohos-2.0.0-beta.1.tar.gz',
  ].join('\n');
  assert.throws(
    () =>
      parseFormalReleaseBundle(FIXTURE, '2.0.0-beta.1', {
        pageHtml,
      }),
    /SDK set/,
  );
});

test('filename parser rejects unknown targets and architectures', () => {
  assert.throws(
    () =>
      parseSdkFilename(
        'cangjie-sdk-linux-riscv64-2.0.0.tar.gz',
        '2.0.0',
      ),
    MetadataError,
  );
  assert.throws(
    () =>
      parseSdkFilename(
        'cangjie-sdk-linux-x64-newtarget-2.0.0.tar.gz',
        '2.0.0',
      ),
    MetadataError,
  );
});

test('release validation rejects bad hashes and duplicate selector identities', () => {
  const release = parseFormalReleaseBundle(FIXTURE, '2.0.0-beta.1');
  const badHash = release.rows.map((row) => ({ ...row }));
  badHash[0].sha256 = 'not-a-sha';
  assert.throws(
    () => validateReleaseRows('2.0.0-beta.1', badHash),
    /invalid SHA-256/,
  );

  const duplicate = [...release.rows, { ...release.rows[0] }];
  duplicate[duplicate.length - 1].filename =
    'cangjie-sdk-windows-x64-2.0.0-beta.1-copy.exe';
  assert.throws(
    () => validateReleaseRows('2.0.0-beta.1', duplicate),
    MetadataError,
  );

  const exeWithoutZip = release.rows.filter(
    (row) => row.format !== 'zip',
  );
  assert.throws(
    () => validateReleaseRows('2.0.0-beta.1', exeWithoutZip),
    /no installable ZIP counterpart/,
  );

  const noMac = release.rows.filter((row) => row.host_os !== 'mac');
  assert.throws(
    () => validateReleaseRows('2.0.0-beta.1', noMac),
    /contains no mac SDK asset/,
  );
});

test('bundle parser fails closed when a required asset field disappears', () => {
  const broken = FIXTURE.replace(
    'sha: "1111111111111111111111111111111111111111111111111111111111111111"',
    'checksum: "1111111111111111111111111111111111111111111111111111111111111111"',
  );
  assert.throws(
    () => parseFormalReleaseBundle(broken, '2.0.0-beta.1'),
    /missing string property sha/,
  );

  const nestedOnly = FIXTURE.replace(
    'sha: "1111111111111111111111111111111111111111111111111111111111111111"',
    'integrity: { sha: "1111111111111111111111111111111111111111111111111111111111111111" }',
  );
  assert.throws(
    () => parseFormalReleaseBundle(nestedOnly, '2.0.0-beta.1'),
    /missing string property sha/,
  );
});

test('official download URL rejects credentials and duplicate query keys', () => {
  const release = parseFormalReleaseBundle(FIXTURE, '2.0.0-beta.1');
  const withCredentials = release.rows.map((row) => ({ ...row }));
  withCredentials[0].url = withCredentials[0].url.replace(
    'https://',
    'https://user:password@',
  );
  assert.throws(
    () => validateReleaseRows('2.0.0-beta.1', withCredentials),
    /not an official Cangjie download URL/,
  );

  const duplicateQuery = release.rows.map((row) => ({ ...row }));
  duplicateQuery[0].url += `&fileName=${encodeURIComponent(
    duplicateQuery[0].filename,
  )}`;
  assert.throws(
    () => validateReleaseRows('2.0.0-beta.1', duplicateQuery),
    /fileName does not match/,
  );
});

test('catalog merge keeps published_at ascending for Bash aliases', () => {
  const rows = [
    {
      version: '1.0.0',
      channel: 'LTS',
      display_name: 'Cangjie 1.0.0',
      published_at: '2025-07-01',
    },
    {
      version: '1.2.0',
      channel: 'STS',
      display_name: 'Cangjie 1.2.0',
      published_at: '2026-07-01',
    },
  ];
  const merged = mergeCatalogRows(rows, {
    version: '1.1.0',
    channel: 'STS',
    display_name: 'Cangjie 1.1.0',
    published_at: '2026-04-24',
  });
  assert.deepEqual(
    merged.map((row) => row.version),
    ['1.0.0', '1.1.0', '1.2.0'],
  );
  assert.ok(renderCatalogTsv(merged).endsWith('\n'));
});

test('discovers only the trusted hashed version bundle', () => {
  const page =
    '<script src="https://csdnimg.cn/release/devpress-cangjie/public/js/' +
    'chunk/organization/download/version.abc123.js"></script>';
  assert.equal(
    discoverVersionBundleUrl(page, 'https://cangjie-lang.cn/download/2.0.0'),
    'https://csdnimg.cn/release/devpress-cangjie/public/js/chunk/' +
      'organization/download/version.abc123.js',
  );
  assert.throws(
    () =>
      discoverVersionBundleUrl(
        page.replace('csdnimg.cn', 'example.invalid'),
        'https://cangjie-lang.cn/download/2.0.0',
      ),
    MetadataError,
  );
});

test('updates a temporary metadata tree, validates it, and is idempotent', async () => {
  const root = mkdtempSync(join(tmpdir(), 'cjman-formal-metadata-'));
  const metadataDir = join(root, 'metadata-v2');
  try {
    cpSync(join(PROJECT_ROOT, 'metadata', 'v2'), metadataDir, {
      recursive: true,
    });
    const catalogBeforePreview = readFileSync(
      join(metadataDir, 'catalog.tsv'),
      'utf8',
    );
    const preview = await updateFormalRelease({
      version: '2.0.0-beta.1',
      metadataDir,
      bundleFile: FIXTURE_PATH,
      dryRun: true,
    });
    assert.equal(preview.dryRun, true);
    assert.equal(
      readFileSync(join(metadataDir, 'catalog.tsv'), 'utf8'),
      catalogBeforePreview,
    );
    assert.equal(
      existsSync(join(metadataDir, 'releases', '2.0.0-beta.1.tsv')),
      false,
    );
    await assert.rejects(
      updateFormalRelease({
        version: '2.0.0-beta.1',
        metadataDir,
        bundleFile: FIXTURE_PATH,
        dryRun: true,
        expectChannel: 'STS',
      }),
      /official site says LTS/,
    );

    const first = await updateFormalRelease({
      version: '2.0.0-beta.1',
      metadataDir,
      bundleFile: FIXTURE_PATH,
      expectChannel: 'LTS',
    });
    assert.equal(first.releaseChanged, true);
    assert.equal(first.catalogChanged, true);
    assert.deepEqual(validateMetadataDirectory(metadataDir), {
      versions: REPOSITORY_BASELINE.versions + 1,
      assets: REPOSITORY_BASELINE.assets + 4,
    });

    const second = await updateFormalRelease({
      version: '2.0.0-beta.1',
      metadataDir,
      bundleFile: FIXTURE_PATH,
    });
    assert.equal(second.releaseChanged, false);
    assert.equal(second.catalogChanged, false);

    const installedPath = join(
      metadataDir,
      'releases',
      '2.0.0-beta.1.tsv',
    );
    writeFileSync(
      installedPath,
      first.releaseText.replace(
        '1111111111111111111111111111111111111111111111111111111111111111',
        'not-a-valid-sha',
      ),
      'utf8',
    );
    const repaired = await updateFormalRelease({
      version: '2.0.0-beta.1',
      metadataDir,
      bundleFile: FIXTURE_PATH,
      replace: true,
    });
    assert.equal(repaired.releaseChanged, true);
    assert.equal(readFileSync(installedPath, 'utf8'), first.releaseText);

    const changedFixture = join(root, 'changed-version.js');
    writeFileSync(
      changedFixture,
      FIXTURE.replace('size: "127.38MB"', 'size: "127.39MB"'),
      'utf8',
    );
    await assert.rejects(
      updateFormalRelease({
        version: '2.0.0-beta.1',
        metadataDir,
        bundleFile: changedFixture,
      }),
      /pass --replace/,
    );
    assert.equal(
      readFileSync(
        join(metadataDir, 'releases', '2.0.0-beta.1.tsv'),
        'utf8',
      ),
      first.releaseText,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('writer lock rejects a concurrent update without leaving an orphan', async () => {
  const root = mkdtempSync(join(tmpdir(), 'cjman-formal-lock-'));
  const metadataDir = join(root, 'metadata-v2');
  try {
    cpSync(REPOSITORY_METADATA_DIR, metadataDir, { recursive: true });
    const first = updateFormalRelease({
      version: '2.0.0-beta.1',
      metadataDir,
      bundleFile: FIXTURE_PATH,
    });
    const second = updateFormalRelease({
      version: '0.53.99',
      metadataDir,
      bundleFile: FIXTURE_PATH,
    });
    const outcomes = await Promise.allSettled([first, second]);
    assert.equal(outcomes.filter((item) => item.status === 'fulfilled').length, 1);
    assert.equal(outcomes.filter((item) => item.status === 'rejected').length, 1);
    assert.match(
      outcomes.find((item) => item.status === 'rejected').reason.message,
      /update is running/,
    );
    assert.deepEqual(validateMetadataDirectory(metadataDir), {
      versions: REPOSITORY_BASELINE.versions + 1,
      assets: REPOSITORY_BASELINE.assets + 4,
    });
    assert.equal(
      existsSync(join(metadataDir, 'releases', '0.53.99.tsv')),
      false,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('a stale lock fails closed before an exact orphan can be recovered', async () => {
  const root = mkdtempSync(join(tmpdir(), 'cjman-formal-recovery-'));
  const metadataDir = join(root, 'metadata-v2');
  try {
    cpSync(REPOSITORY_METADATA_DIR, metadataDir, { recursive: true });
    const preview = await updateFormalRelease({
      version: '2.0.0-beta.1',
      metadataDir,
      bundleFile: FIXTURE_PATH,
      dryRun: true,
    });
    writeFileSync(
      join(metadataDir, 'releases', '2.0.0-beta.1.tsv'),
      preview.releaseText,
      'utf8',
    );
    writeFileSync(
      join(metadataDir, '.formal-release-update.lock'),
      `${JSON.stringify({
        pid: 99_999_999,
        token: 'dead-writer',
        started_at: '2000-01-01T00:00:00.000Z',
      })}\n`,
      'utf8',
    );

    const lockPath = join(metadataDir, '.formal-release-update.lock');
    await assert.rejects(
      updateFormalRelease({
        version: '2.0.0-beta.1',
        metadataDir,
        bundleFile: FIXTURE_PATH,
      }),
      /Stale metadata lock/,
    );
    assert.equal(existsSync(lockPath), true);

    rmSync(lockPath, { force: true });
    const recovered = await updateFormalRelease({
      version: '2.0.0-beta.1',
      metadataDir,
      bundleFile: FIXTURE_PATH,
    });
    assert.equal(recovered.releaseChanged, false);
    assert.equal(recovered.catalogChanged, true);
    assert.deepEqual(validateMetadataDirectory(metadataDir), {
      versions: REPOSITORY_BASELINE.versions + 1,
      assets: REPOSITORY_BASELINE.assets + 4,
    });
    assert.equal(existsSync(lockPath), false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('the repository metadata contract covers all current formal assets', () => {
  const catalogRows =
    readFileSync(join(REPOSITORY_METADATA_DIR, 'catalog.tsv'), 'utf8')
      .trimEnd()
      .split('\n').length - 1;
  assert.equal(REPOSITORY_BASELINE.versions, catalogRows);
  assert.ok(REPOSITORY_BASELINE.versions > 0);
  assert.ok(
    REPOSITORY_BASELINE.assets >= REPOSITORY_BASELINE.versions,
  );
});
