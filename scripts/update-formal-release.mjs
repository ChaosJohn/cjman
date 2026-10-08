#!/usr/bin/env node

import {
  closeSync,
  existsSync,
  openSync,
  readFileSync,
  readdirSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
  fsyncSync,
  mkdirSync,
} from 'node:fs';
import { randomUUID } from 'node:crypto';
import { dirname, join, resolve, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const OFFICIAL_ORIGIN = 'https://cangjie-lang.cn';
const CATALOG_COLUMNS = [
  'version',
  'channel',
  'display_name',
  'published_at',
];
const RELEASE_COLUMNS = [
  'component',
  'host_os',
  'host_arch',
  'target_os',
  'target_arch',
  'flavor',
  'format',
  'filename',
  'url',
  'sha256',
  'size',
];
const FORMATS = ['tar.gz', 'zip', 'exe'];
const TARGET_OSES = new Set([
  'android',
  'ohos',
  'ios',
  'ios-simulator',
]);
const HOST_OS_ALIASES = new Map([
  ['windows', 'windows'],
  ['linux', 'linux'],
  ['mac', 'mac'],
  ['macos', 'mac'],
  ['darwin', 'mac'],
]);
const ARCH_ALIASES = new Map([
  ['x64', 'x64'],
  ['x86_64', 'x64'],
  ['amd64', 'x64'],
  ['aarch64', 'aarch64'],
  ['arm64', 'aarch64'],
  ['arm32', 'arm32'],
  ['armv7', 'arm32'],
  ['armv7l', 'arm32'],
]);
const SCRIPT_PATH = fileURLToPath(import.meta.url);
const DEFAULT_METADATA_DIR = resolve(dirname(SCRIPT_PATH), '..', 'metadata', 'v2');
const MAX_SOURCE_BYTES = 16 * 1024 * 1024;

export class MetadataError extends Error {
  constructor(message) {
    super(message);
    this.name = 'MetadataError';
  }
}

function fail(message) {
  throw new MetadataError(message);
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function assertSafeVersion(version) {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(version)) {
    fail(`Invalid version ${JSON.stringify(version)}.`);
  }
}

function assertPlainField(value, label) {
  if (typeof value !== 'string' || value.length === 0) {
    fail(`${label} must not be empty.`);
  }
  if (/[\u0000-\u001f\u007f]/.test(value)) {
    fail(`${label} contains a control character.`);
  }
}

function normalizeDate(value, label, allowSlash = true) {
  assertPlainField(value, label);
  const separator = allowSlash ? '[-/]' : '-';
  const match = value.match(
    new RegExp(`^(\\d{4})${separator}(\\d{2})${separator}(\\d{2})$`),
  );
  if (!match) {
    fail(`${label} is not a YYYY-MM-DD date: ${value}`);
  }
  const normalized = `${match[1]}-${match[2]}-${match[3]}`;
  const parsed = new Date(`${normalized}T00:00:00Z`);
  if (
    Number.isNaN(parsed.getTime()) ||
    parsed.toISOString().slice(0, 10) !== normalized
  ) {
    fail(`${label} is not a real calendar date: ${value}`);
  }
  return normalized;
}

function normalizeHostOs(value, label) {
  const normalized = HOST_OS_ALIASES.get(value.toLowerCase());
  if (!normalized) {
    fail(`${label} contains an unsupported host OS: ${value}`);
  }
  return normalized;
}

function normalizeArch(value, label, optional = false) {
  const normalized = ARCH_ALIASES.get(value.toLowerCase());
  if (!normalized && !optional) {
    fail(`${label} contains an unsupported architecture: ${value}`);
  }
  return normalized ?? null;
}

function readJsString(source, quoteIndex) {
  const quote = source[quoteIndex];
  if (quote !== '"' && quote !== "'") {
    fail('Internal parser error: expected a JavaScript string.');
  }

  let value = '';
  for (let index = quoteIndex + 1; index < source.length; index += 1) {
    const character = source[index];
    if (character === quote) {
      return { value, end: index + 1 };
    }
    if (character !== '\\') {
      value += character;
      continue;
    }

    index += 1;
    if (index >= source.length) {
      fail('Unterminated escape sequence in the official version bundle.');
    }
    const escaped = source[index];
    const simpleEscapes = {
      b: '\b',
      f: '\f',
      n: '\n',
      r: '\r',
      t: '\t',
      v: '\v',
      0: '\0',
    };
    if (Object.hasOwn(simpleEscapes, escaped)) {
      value += simpleEscapes[escaped];
      continue;
    }
    if (escaped === '\n') {
      continue;
    }
    if (escaped === '\r') {
      if (source[index + 1] === '\n') {
        index += 1;
      }
      continue;
    }
    if (escaped === 'x') {
      const digits = source.slice(index + 1, index + 3);
      if (!/^[0-9A-Fa-f]{2}$/.test(digits)) {
        fail('Invalid hexadecimal escape in the official version bundle.');
      }
      value += String.fromCodePoint(Number.parseInt(digits, 16));
      index += 2;
      continue;
    }
    if (escaped === 'u') {
      if (source[index + 1] === '{') {
        const close = source.indexOf('}', index + 2);
        const digits = source.slice(index + 2, close);
        if (
          close === -1 ||
          !/^[0-9A-Fa-f]{1,6}$/.test(digits) ||
          Number.parseInt(digits, 16) > 0x10ffff
        ) {
          fail('Invalid Unicode escape in the official version bundle.');
        }
        value += String.fromCodePoint(Number.parseInt(digits, 16));
        index = close;
        continue;
      }
      const digits = source.slice(index + 1, index + 5);
      if (!/^[0-9A-Fa-f]{4}$/.test(digits)) {
        fail('Invalid Unicode escape in the official version bundle.');
      }
      value += String.fromCodePoint(Number.parseInt(digits, 16));
      index += 4;
      continue;
    }
    value += escaped;
  }
  fail('Unterminated string in the official version bundle.');
}

function extractBalancedObject(source, openIndex) {
  if (source[openIndex] !== '{') {
    fail('Internal parser error: expected an object opening brace.');
  }

  let depth = 0;
  let quote = null;
  let escaped = false;
  let lineComment = false;
  let blockComment = false;

  for (let index = openIndex; index < source.length; index += 1) {
    const character = source[index];
    const next = source[index + 1];

    if (lineComment) {
      if (character === '\n' || character === '\r') {
        lineComment = false;
      }
      continue;
    }
    if (blockComment) {
      if (character === '*' && next === '/') {
        blockComment = false;
        index += 1;
      }
      continue;
    }
    if (quote !== null) {
      if (escaped) {
        escaped = false;
      } else if (character === '\\') {
        escaped = true;
      } else if (character === quote) {
        quote = null;
      }
      continue;
    }
    if (character === '/' && next === '/') {
      lineComment = true;
      index += 1;
      continue;
    }
    if (character === '/' && next === '*') {
      blockComment = true;
      index += 1;
      continue;
    }
    if (character === '"' || character === "'" || character === '`') {
      quote = character;
      continue;
    }
    if (character === '{') {
      depth += 1;
      continue;
    }
    if (character === '}') {
      depth -= 1;
      if (depth === 0) {
        return {
          text: source.slice(openIndex, index + 1),
          end: index + 1,
        };
      }
      if (depth < 0) {
        break;
      }
    }
  }
  fail('Unbalanced object in the official version bundle.');
}

function skipWhitespaceAndComments(source, start, label) {
  let index = start;
  while (index < source.length) {
    if (/\s/.test(source[index])) {
      index += 1;
      continue;
    }
    if (source[index] === '/' && source[index + 1] === '/') {
      const newline = source.indexOf('\n', index + 2);
      return newline === -1
        ? source.length
        : skipWhitespaceAndComments(source, newline + 1, label);
    }
    if (source[index] === '/' && source[index + 1] === '*') {
      const close = source.indexOf('*/', index + 2);
      if (close === -1) {
        fail(`${label} contains an unterminated comment.`);
      }
      index = close + 2;
      continue;
    }
    break;
  }
  return index;
}

function scanPropertyValueEnd(source, start, label) {
  let curly = 0;
  let square = 0;
  let parenthesis = 0;

  for (let index = start; index < source.length; index += 1) {
    const character = source[index];
    const next = source[index + 1];
    if (character === '"' || character === "'") {
      index = readJsString(source, index).end - 1;
      continue;
    }
    if (character === '`') {
      fail(`${label} contains an unsupported template literal.`);
    }
    if (character === '/' && next === '/') {
      const newline = source.indexOf('\n', index + 2);
      if (newline === -1) {
        return source.length;
      }
      index = newline;
      continue;
    }
    if (character === '/' && next === '*') {
      const close = source.indexOf('*/', index + 2);
      if (close === -1) {
        fail(`${label} contains an unterminated comment.`);
      }
      index = close + 1;
      continue;
    }
    if (character === '{') {
      curly += 1;
    } else if (character === '}') {
      if (curly === 0 && square === 0 && parenthesis === 0) {
        return index;
      }
      curly -= 1;
    } else if (character === '[') {
      square += 1;
    } else if (character === ']') {
      square -= 1;
    } else if (character === '(') {
      parenthesis += 1;
    } else if (character === ')') {
      parenthesis -= 1;
    } else if (
      character === ',' &&
      curly === 0 &&
      square === 0 &&
      parenthesis === 0
    ) {
      return index;
    }
    if (curly < 0 || square < 0 || parenthesis < 0) {
      fail(`${label} contains unbalanced property delimiters.`);
    }
  }
  fail(`${label} contains an unterminated property value.`);
}

function topLevelProperties(objectSource, label) {
  if (!objectSource.startsWith('{') || !objectSource.endsWith('}')) {
    fail(`${label} is not a complete object literal.`);
  }
  const properties = new Map();
  let index = 1;

  while (index < objectSource.length - 1) {
    index = skipWhitespaceAndComments(objectSource, index, label);
    if (objectSource[index] === '}') {
      break;
    }

    let key;
    if (objectSource[index] === '"' || objectSource[index] === "'") {
      const parsed = readJsString(objectSource, index);
      key = parsed.value;
      index = parsed.end;
    } else {
      const match = /^[A-Za-z_$][A-Za-z0-9_$]*/.exec(
        objectSource.slice(index),
      );
      if (!match) {
        fail(`${label} contains an unsupported property key.`);
      }
      key = match[0];
      index += key.length;
    }
    index = skipWhitespaceAndComments(objectSource, index, label);
    if (objectSource[index] !== ':') {
      fail(`${label} property ${key} is missing a colon.`);
    }
    index = skipWhitespaceAndComments(objectSource, index + 1, label);
    const valueStart = index;
    const valueEnd = scanPropertyValueEnd(objectSource, valueStart, label);
    if (properties.has(key)) {
      fail(`${label} contains duplicate property ${key}.`);
    }
    properties.set(key, {
      source: objectSource.slice(valueStart, valueEnd).trim(),
      start: valueStart,
      end: valueEnd,
    });
    index = skipWhitespaceAndComments(objectSource, valueEnd, label);
    if (objectSource[index] === ',') {
      index += 1;
    } else if (objectSource[index] !== '}') {
      fail(`${label} property ${key} is not followed by a comma or closing brace.`);
    }
  }
  return properties;
}

function optionalStringProperty(
  objectSource,
  property,
  label,
  { allowNonString = false } = {},
) {
  const propertyValue = topLevelProperties(objectSource, label).get(property);
  if (!propertyValue) {
    return null;
  }
  const source = propertyValue.source;
  if (source[0] !== '"' && source[0] !== "'") {
    if (allowNonString) {
      return null;
    }
    fail(`${label} property ${property} is not a string literal.`);
  }
  const parsed = readJsString(source, 0);
  if (source.slice(parsed.end).trim().length !== 0) {
    fail(`${label} property ${property} is not a plain string literal.`);
  }
  return parsed.value;
}

function propertySource(objectSource, property, label) {
  const propertyValue = topLevelProperties(objectSource, label).get(property);
  if (!propertyValue) {
    fail(`${label} is missing property ${property}.`);
  }
  return propertyValue.source;
}

function stringProperty(objectSource, property, label) {
  const value = optionalStringProperty(objectSource, property, label);
  if (value === null) {
    fail(`${label} is missing string property ${property}.`);
  }
  return value;
}

function arrayObjectElements(arraySource, label) {
  if (!arraySource.startsWith('[') || !arraySource.endsWith(']')) {
    fail(`${label} is not an array literal.`);
  }
  const elements = [];
  let index = 1;

  while (index < arraySource.length - 1) {
    index = skipWhitespaceAndComments(arraySource, index, label);
    if (arraySource[index] === ']') {
      break;
    }
    if (arraySource[index] !== '{') {
      fail(`${label} contains a non-object asset entry.`);
    }
    const object = extractBalancedObject(arraySource, index);
    elements.push(object.text);
    index = skipWhitespaceAndComments(arraySource, object.end, label);
    if (arraySource[index] === ',') {
      index += 1;
    } else if (arraySource[index] !== ']') {
      fail(`${label} asset entry is not followed by a comma or closing bracket.`);
    }
  }
  return elements;
}

function findVersionObject(bundle, version) {
  const pattern = new RegExp(
    `(["'])${escapeRegExp(version)}\\1\\s*:\\s*\\{\\s*(?:"time"|'time'|time)\\s*:`,
    'g',
  );
  const candidates = [];
  let match;
  while ((match = pattern.exec(bundle)) !== null) {
    const openIndex = bundle.indexOf('{', match.index);
    candidates.push(extractBalancedObject(bundle, openIndex).text);
  }
  if (candidates.length !== 1) {
    fail(
      `Expected exactly one official release object for ${version}, found ${candidates.length}.`,
    );
  }
  return candidates[0];
}

function findSdkAssetObjects(versionObject, version) {
  const assets = [];
  const sdkGroupNames = new Set(['Windows', 'Mac', 'Linux']);
  const sdkGroupHosts = new Map([
    ['Windows', 'windows'],
    ['Mac', 'mac'],
    ['Linux', 'linux'],
  ]);
  const seenGroups = new Set();
  const releaseSections = arrayObjectElements(
    propertySource(
      versionObject,
      'list',
      `official release ${version}`,
    ),
    `section list in release ${version}`,
  );
  const sdkSections = releaseSections.filter(
    (sectionSource) =>
      optionalStringProperty(
        sectionSource,
        'name',
        `section in release ${version}`,
        { allowNonString: true },
      ) === '',
  );
  if (sdkSections.length !== 1) {
    fail(
      `Expected exactly one SDK section in release ${version}, found ${sdkSections.length}.`,
    );
  }
  const sdkGroups = arrayObjectElements(
    propertySource(
      sdkSections[0],
      'list',
      `SDK section in release ${version}`,
    ),
    `SDK platform list in release ${version}`,
  );

  for (const groupSource of sdkGroups) {
    const name = stringProperty(
      groupSource,
      'name',
      `SDK platform group in release ${version}`,
    );
    if (!sdkGroupNames.has(name)) {
      fail(
        `Official release ${version} contains an unsupported SDK platform group: ${name}.`,
      );
    }
    if (seenGroups.has(name)) {
      fail(`Official release ${version} contains duplicate ${name} SDK groups.`);
    }
    seenGroups.add(name);
    const list = propertySource(
      groupSource,
      'list',
      `${name} SDK group in release ${version}`,
    );
    const groupAssets = arrayObjectElements(
      list,
      `${name} SDK list in release ${version}`,
    );
    if (groupAssets.length === 0) {
      fail(`Official release ${version} has an empty ${name} SDK group.`);
    }
    for (const assetSource of groupAssets) {
      const assetName = stringProperty(
        assetSource,
        'name',
        `${name} SDK asset in release ${version}`,
      );
      const parsedIdentity = parseSdkFilename(assetName, version);
      if (parsedIdentity.host_os !== sdkGroupHosts.get(name)) {
        fail(
          `SDK asset ${assetName} is listed under ${name}, but its filename identifies host ${parsedIdentity.host_os}.`,
        );
      }
      assets.push({
        source: assetSource,
        name: assetName,
      });
    }
  }
  for (const groupName of sdkGroupNames) {
    if (!seenGroups.has(groupName)) {
      fail(`Official release ${version} is missing the ${groupName} SDK group.`);
    }
  }
  return assets;
}

function detectFormat(filename) {
  for (const format of FORMATS) {
    if (filename.endsWith(`.${format}`)) {
      return format;
    }
  }
  fail(`Unsupported SDK archive format in ${filename}.`);
}

export function parseSdkFilename(filename, version) {
  assertPlainField(filename, 'SDK filename');
  assertSafeVersion(version);
  if (
    basename(filename) !== filename ||
    filename.includes('/') ||
    filename.includes('\\')
  ) {
    fail(`SDK filename is not a basename: ${filename}`);
  }

  const format = detectFormat(filename);
  const stem = filename.slice(0, -(`.${format}`.length));
  const legacyPrefix = `Cangjie-${version}-`;

  if (stem.startsWith(legacyPrefix)) {
    const identity = stem.slice(legacyPrefix.length);
    const separator = identity.lastIndexOf('_');
    if (separator <= 0 || separator === identity.length - 1) {
      fail(`Unrecognized legacy SDK filename: ${filename}`);
    }
    const hostOs = normalizeHostOs(
      identity.slice(0, separator),
      `SDK filename ${filename}`,
    );
    const hostArch = normalizeArch(
      identity.slice(separator + 1),
      `SDK filename ${filename}`,
    );
    return {
      host_os: hostOs,
      host_arch: hostArch,
      target_os: 'native',
      target_arch: hostArch,
      format,
    };
  }

  const modernPrefix = 'cangjie-sdk-';
  const versionSuffix = `-${version}`;
  if (!stem.startsWith(modernPrefix) || !stem.endsWith(versionSuffix)) {
    fail(`Unrecognized SDK filename for ${version}: ${filename}`);
  }

  const identity = stem.slice(
    modernPrefix.length,
    stem.length - versionSuffix.length,
  );
  const parts = identity.split('-');
  if (parts.length < 2 || parts.some((part) => part.length === 0)) {
    fail(`Incomplete SDK host identity in ${filename}.`);
  }

  const hostOs = normalizeHostOs(parts.shift(), `SDK filename ${filename}`);
  const hostArch = normalizeArch(parts.shift(), `SDK filename ${filename}`);
  if (parts.length === 0) {
    return {
      host_os: hostOs,
      host_arch: hostArch,
      target_os: 'native',
      target_arch: hostArch,
      format,
    };
  }

  let targetArch = 'any';
  if (parts.length >= 2) {
    const explicitArch = normalizeArch(
      parts[parts.length - 1],
      `SDK filename ${filename}`,
      true,
    );
    if (explicitArch) {
      targetArch = explicitArch;
      parts.pop();
    }
  }
  const targetOs = parts.join('-').toLowerCase();
  if (!TARGET_OSES.has(targetOs)) {
    fail(`SDK filename ${filename} contains an unsupported target: ${targetOs}`);
  }
  return {
    host_os: hostOs,
    host_arch: hostArch,
    target_os: targetOs,
    target_arch: targetArch,
    format,
  };
}

function validateOfficialDownloadUrl(value, filename, label) {
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    fail(`${label} is not a valid URL: ${value}`);
  }
  if (
    parsed.origin !== OFFICIAL_ORIGIN ||
    parsed.username !== '' ||
    parsed.password !== '' ||
    parsed.hash !== '' ||
    parsed.pathname !== '/v1/files/auth/downLoad'
  ) {
    fail(`${label} is not an official Cangjie download URL: ${value}`);
  }
  const fileNames = parsed.searchParams.getAll('fileName');
  const namespaceIds = parsed.searchParams.getAll('nsId');
  const objectKeys = parsed.searchParams.getAll('objectKey');
  if (fileNames.length !== 1 || fileNames[0] !== filename) {
    fail(`${label} fileName does not match ${filename}.`);
  }
  if (namespaceIds.length !== 1 || !/^\d+$/.test(namespaceIds[0])) {
    fail(`${label} is missing a numeric nsId.`);
  }
  if (
    objectKeys.length !== 1 ||
    !/^[A-Za-z0-9]+$/.test(objectKeys[0])
  ) {
    fail(`${label} is missing a valid objectKey.`);
  }
  return parsed;
}

export function validateReleaseRows(version, rows, label = `release ${version}`) {
  assertSafeVersion(version);
  if (!Array.isArray(rows) || rows.length === 0) {
    fail(`${label} contains no SDK rows.`);
  }

  const filenames = new Set();
  const urls = new Set();
  const objectKeys = new Set();
  const identities = new Set();
  const hosts = new Set();
  let installableAssets = 0;
  let previousHostRank = -1;
  const hostRanks = new Map([
    ['windows', 0],
    ['mac', 1],
    ['linux', 2],
  ]);

  for (const [index, row] of rows.entries()) {
    const rowLabel = `${label} row ${index + 2}`;
    for (const column of RELEASE_COLUMNS) {
      assertPlainField(row[column], `${rowLabel} column ${column}`);
    }
    if (row.component !== 'sdk') {
      fail(`${rowLabel} has unsupported component ${row.component}.`);
    }
    if (row.flavor !== 'default') {
      fail(`${rowLabel} has unsupported flavor ${row.flavor}.`);
    }
    if (!/^[0-9A-Fa-f]{64}$/.test(row.sha256)) {
      fail(`${rowLabel} has an invalid SHA-256.`);
    }
    if (!/^(?:0|[1-9]\d*)(?:\.\d+)?(?:B|KB|MB|GB|TB)$/.test(row.size)) {
      fail(`${rowLabel} has an invalid package size: ${row.size}`);
    }

    const parsedName = parseSdkFilename(row.filename, version);
    for (const field of [
      'host_os',
      'host_arch',
      'target_os',
      'target_arch',
      'format',
    ]) {
      if (row[field] !== parsedName[field]) {
        fail(
          `${rowLabel} ${field}=${row[field]} disagrees with filename ${row.filename}.`,
        );
      }
    }
    const hostRank = hostRanks.get(row.host_os);
    hosts.add(row.host_os);
    if (hostRank < previousHostRank) {
      fail(`${rowLabel} breaks the required Windows, Mac, Linux host order.`);
    }
    previousHostRank = hostRank;
    if (row.format === 'exe' && row.host_os !== 'windows') {
      fail(`${rowLabel} uses EXE for a non-Windows host.`);
    }
    if (row.format !== 'exe') {
      installableAssets += 1;
    }

    const parsedUrl = validateOfficialDownloadUrl(
      row.url,
      row.filename,
      `${rowLabel} URL`,
    );
    const objectKey = parsedUrl.searchParams.get('objectKey');
    const identity = [
      row.component,
      row.host_os,
      row.host_arch,
      row.target_os,
      row.target_arch,
      row.flavor,
      row.format,
    ].join('\t');

    for (const [set, key, kind] of [
      [filenames, row.filename, 'filename'],
      [urls, row.url, 'URL'],
      [objectKeys, objectKey, 'objectKey'],
      [identities, identity, 'selector identity'],
    ]) {
      if (set.has(key)) {
        fail(`${rowLabel} duplicates ${kind} ${key}.`);
      }
      set.add(key);
    }
  }

  if (installableAssets === 0) {
    fail(`${label} contains no installable ZIP or TAR archive.`);
  }
  for (const requiredHost of hostRanks.keys()) {
    if (!hosts.has(requiredHost)) {
      fail(`${label} contains no ${requiredHost} SDK asset.`);
    }
  }

  for (const row of rows) {
    if (row.host_os !== 'windows' || row.format !== 'exe') {
      continue;
    }
    const matchingZip = rows.some(
      (candidate) =>
        candidate.host_os === row.host_os &&
        candidate.host_arch === row.host_arch &&
        candidate.target_os === row.target_os &&
        candidate.target_arch === row.target_arch &&
        candidate.flavor === row.flavor &&
        candidate.format === 'zip',
    );
    if (!matchingZip) {
      fail(`Windows EXE ${row.filename} has no installable ZIP counterpart.`);
    }
  }
}

export function parseFormalReleaseBundle(
  bundle,
  version,
  { pageHtml = null, origin = OFFICIAL_ORIGIN } = {},
) {
  assertSafeVersion(version);
  if (typeof bundle !== 'string' || bundle.length === 0) {
    fail('Official version bundle is empty.');
  }
  const object = findVersionObject(bundle, version);
  const releaseVersion = stringProperty(object, 'version', `release ${version}`);
  const displayName = stringProperty(object, 'name', `release ${version}`);
  const channel = stringProperty(object, 'versiontype', `release ${version}`);
  const rawDate = stringProperty(object, 'time', `release ${version}`);
  const publishedAt = normalizeDate(
    rawDate,
    `release ${version} publication date`,
  );

  if (releaseVersion !== version) {
    fail(
      `Official release key ${version} contains version ${releaseVersion}.`,
    );
  }
  if (channel !== 'LTS' && channel !== 'STS') {
    fail(`Official release ${version} has unsupported channel ${channel}.`);
  }
  assertPlainField(displayName, `release ${version} display name`);

  const rows = [];
  for (const asset of findSdkAssetObjects(object, version)) {
    const filename = asset.name;
    const assetVersion = stringProperty(
      asset.source,
      'version',
      `asset ${filename}`,
    );
    const assetDate = normalizeDate(
      stringProperty(asset.source, 'time', `asset ${filename}`),
      `asset ${filename} publication date`,
    );
    const relativeUrl = stringProperty(asset.source, 'url', `asset ${filename}`);
    const sha256 = stringProperty(asset.source, 'sha', `asset ${filename}`);
    const size = stringProperty(asset.source, 'size', `asset ${filename}`);

    if (assetVersion !== version) {
      fail(`Asset ${filename} belongs to version ${assetVersion}, not ${version}.`);
    }
    if (assetDate !== publishedAt) {
      fail(
        `Asset ${filename} date ${assetDate} disagrees with release date ${publishedAt}.`,
      );
    }

    let url;
    try {
      url = new URL(relativeUrl, origin).href;
    } catch {
      fail(`Asset ${filename} has an invalid URL: ${relativeUrl}`);
    }
    const identity = parseSdkFilename(filename, version);
    rows.push({
      component: 'sdk',
      ...identity,
      flavor: 'default',
      filename,
      url,
      sha256,
      size,
    });
  }

  validateReleaseRows(version, rows, `official release ${version}`);

  if (pageHtml !== null) {
    if (!pageHtml.includes(displayName) || !pageHtml.includes(rawDate)) {
      fail(`Version page does not display ${displayName} and ${rawDate}.`);
    }
    const pagePatterns = [
      new RegExp(
        `cangjie-sdk-[A-Za-z0-9._-]+-${escapeRegExp(version)}\\.(?:tar\\.gz|zip|exe)`,
        'g',
      ),
      new RegExp(
        `Cangjie-${escapeRegExp(version)}-[A-Za-z0-9._-]+\\.(?:tar\\.gz|zip|exe)`,
        'g',
      ),
    ];
    const visibleFilenames = new Set(
      pagePatterns.flatMap((pattern) => pageHtml.match(pattern) ?? []),
    );
    const parsedFilenames = new Set(rows.map((row) => row.filename));
    if (
      visibleFilenames.size !== parsedFilenames.size ||
      [...visibleFilenames].some((filename) => !parsedFilenames.has(filename))
    ) {
      fail(
        `Version page SDK set (${visibleFilenames.size}) disagrees with parsed bundle SDK set (${parsedFilenames.size}).`,
      );
    }
    for (const row of rows) {
      if (!pageHtml.includes(row.filename) || !pageHtml.includes(row.size)) {
        fail(
          `Version page does not display bundle asset ${row.filename} (${row.size}).`,
        );
      }
    }
  }

  return {
    catalog: {
      version,
      channel,
      display_name: displayName,
      published_at: publishedAt,
    },
    rows,
  };
}

function parseTsv(text, columns, label) {
  if (typeof text !== 'string' || text.length === 0) {
    fail(`${label} is empty.`);
  }
  if (text.charCodeAt(0) === 0xfeff) {
    fail(`${label} must not contain a UTF-8 BOM.`);
  }
  if (text.includes('\r')) {
    fail(`${label} must use LF line endings.`);
  }
  if (!text.endsWith('\n')) {
    fail(`${label} must end with a newline.`);
  }

  const lines = text.slice(0, -1).split('\n');
  const expectedHeader = columns.join('\t');
  if (lines[0] !== expectedHeader) {
    fail(`${label} has an unexpected header.`);
  }
  return lines.slice(1).map((line, index) => {
    if (line.length === 0) {
      fail(`${label} contains an empty row at line ${index + 2}.`);
    }
    const fields = line.split('\t');
    if (fields.length !== columns.length) {
      fail(
        `${label} line ${index + 2} has ${fields.length} columns; expected ${columns.length}.`,
      );
    }
    return Object.fromEntries(columns.map((column, offset) => [
      column,
      fields[offset],
    ]));
  });
}

function renderTsv(columns, rows) {
  const lines = [columns.join('\t')];
  for (const row of rows) {
    lines.push(columns.map((column) => row[column]).join('\t'));
  }
  return `${lines.join('\n')}\n`;
}

export function parseCatalogTsv(
  text,
  label = 'catalog.tsv',
  { skipVersion = null } = {},
) {
  const rows = parseTsv(text, CATALOG_COLUMNS, label);
  const versions = new Set();
  let previousDate = '';

  for (const [index, row] of rows.entries()) {
    if (skipVersion !== null && row.version === skipVersion) {
      continue;
    }
    const rowLabel = `${label} row ${index + 2}`;
    assertSafeVersion(row.version);
    for (const column of CATALOG_COLUMNS) {
      assertPlainField(row[column], `${rowLabel} column ${column}`);
    }
    if (row.channel !== 'LTS' && row.channel !== 'STS') {
      fail(`${rowLabel} has unsupported channel ${row.channel}.`);
    }
    const normalizedDate = normalizeDate(
      row.published_at,
      `${rowLabel} publication date`,
      false,
    );
    if (versions.has(row.version)) {
      fail(`${rowLabel} duplicates version ${row.version}.`);
    }
    if (previousDate && normalizedDate < previousDate) {
      fail(`${label} is not sorted by published_at at ${row.version}.`);
    }
    versions.add(row.version);
    previousDate = normalizedDate;
  }
  return rows;
}

export function parseReleaseTsv(text, version, label = `${version}.tsv`) {
  const rows = parseTsv(text, RELEASE_COLUMNS, label);
  validateReleaseRows(version, rows, label);
  return rows;
}

export function renderReleaseTsv(rows) {
  return renderTsv(RELEASE_COLUMNS, rows);
}

export function renderCatalogTsv(rows) {
  return renderTsv(CATALOG_COLUMNS, rows);
}

export function mergeCatalogRows(rows, record) {
  const merged = rows.filter((row) => row.version !== record.version);
  merged.push({ ...record });
  const collator = new Intl.Collator('en', {
    numeric: true,
    sensitivity: 'base',
  });
  merged.sort(
    (left, right) =>
      left.published_at.localeCompare(right.published_at) ||
      collator.compare(left.version, right.version),
  );
  parseCatalogTsv(renderCatalogTsv(merged), 'generated catalog.tsv');
  return merged;
}

export function validateMetadataDirectory(
  metadataDir = DEFAULT_METADATA_DIR,
  version = null,
  { skipVersion = null } = {},
) {
  const resolvedDir = resolve(metadataDir);
  const catalogPath = join(resolvedDir, 'catalog.tsv');
  const releasesDir = join(resolvedDir, 'releases');
  const catalogRows = parseCatalogTsv(
    readFileSync(catalogPath, 'utf8'),
    catalogPath,
    { skipVersion },
  );
  const selectedRows = version
    ? catalogRows.filter((row) => row.version === version)
    : catalogRows.filter((row) => row.version !== skipVersion);
  if (version && selectedRows.length !== 1) {
    fail(`Version ${version} is not present in ${catalogPath}.`);
  }

  let assetCount = 0;
  for (const row of selectedRows) {
    const releasePath = join(releasesDir, `${row.version}.tsv`);
    if (!existsSync(releasePath)) {
      fail(`${catalogPath} references missing manifest ${releasePath}.`);
    }
    assetCount += parseReleaseTsv(
      readFileSync(releasePath, 'utf8'),
      row.version,
      releasePath,
    ).length;
  }

  if (!version) {
    const expected = new Set(
      catalogRows
        .filter((row) => row.version !== skipVersion)
        .map((row) => `${row.version}.tsv`),
    );
    const ignoredManifest =
      skipVersion === null ? null : `${skipVersion}.tsv`;
    const actual = readdirSync(releasesDir).filter(
      (name) => name.endsWith('.tsv') && name !== ignoredManifest,
    );
    for (const filename of actual) {
      if (!expected.has(filename)) {
        fail(`Orphan release manifest is not in catalog.tsv: ${filename}`);
      }
    }
    if (actual.length !== expected.size) {
      fail('Release manifest count does not match catalog.tsv.');
    }
  }

  return {
    versions: selectedRows.length,
    assets: assetCount,
  };
}

function validateBundleUrl(value) {
  const url = new URL(value);
  const trustedHost =
    url.hostname === 'csdnimg.cn' || url.hostname.endsWith('.csdnimg.cn');
  const trustedPath =
    /^\/release\/devpress-cangjie\/public\/js\/chunk\/organization\/download\/version\.[A-Za-z0-9_-]+\.js$/.test(
      url.pathname,
    );
  if (
    url.protocol !== 'https:' ||
    url.port !== '' ||
    url.username !== '' ||
    url.password !== '' ||
    url.hash !== '' ||
    !trustedHost ||
    !trustedPath
  ) {
    fail(`Version page referenced an untrusted bundle URL: ${url.href}`);
  }
  return url;
}

export function discoverVersionBundleUrl(pageHtml, pageUrl) {
  const pattern = /<script\b[^>]*\bsrc=(["'])([^"']+)\1[^>]*>/gi;
  const candidates = new Set();
  let match;
  while ((match = pattern.exec(pageHtml)) !== null) {
    const source = match[2].replaceAll('&amp;', '&');
    let url;
    try {
      url = new URL(source, pageUrl);
    } catch {
      continue;
    }
    if (
      /\/organization\/download\/version\.[A-Za-z0-9_-]+\.js$/.test(
        url.pathname,
      )
    ) {
      candidates.add(validateBundleUrl(url.href).href);
    }
  }
  if (candidates.size !== 1) {
    fail(
      `Expected one version bundle in ${pageUrl}, found ${candidates.size}.`,
    );
  }
  return [...candidates][0];
}

async function fetchText(url, accept) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 20_000);
  try {
    const response = await fetch(url, {
      redirect: 'follow',
      signal: controller.signal,
      headers: {
        Accept: accept,
        'User-Agent': 'cjman-formal-metadata-updater/1',
      },
    });
    if (!response.ok) {
      fail(`Failed to fetch ${url}: HTTP ${response.status}.`);
    }
    const declaredLength = Number(response.headers.get('content-length') ?? 0);
    if (declaredLength > MAX_SOURCE_BYTES) {
      controller.abort();
      fail(`Refusing oversized response from ${url}.`);
    }
    if (!response.body) {
      fail(`Failed to fetch ${url}: response body is empty.`);
    }

    const reader = response.body.getReader();
    const chunks = [];
    let totalBytes = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }
      totalBytes += value.byteLength;
      if (totalBytes > MAX_SOURCE_BYTES) {
        await reader.cancel();
        controller.abort();
        fail(`Refusing oversized response from ${url}.`);
      }
      chunks.push(Buffer.from(value));
    }
    const text = Buffer.concat(chunks, totalBytes).toString('utf8');
    return { text, finalUrl: response.url };
  } catch (error) {
    if (error instanceof MetadataError) {
      throw error;
    }
    fail(`Failed to fetch ${url}: ${error.message}`);
  } finally {
    clearTimeout(timeout);
  }
}

export async function fetchFormalReleaseSource(version) {
  assertSafeVersion(version);
  const pageUrl = new URL(
    `/download/${encodeURIComponent(version)}`,
    OFFICIAL_ORIGIN,
  ).href;
  const page = await fetchText(pageUrl, 'text/html');
  const finalPageUrl = new URL(page.finalUrl);
  if (
    finalPageUrl.origin !== OFFICIAL_ORIGIN ||
    finalPageUrl.username !== '' ||
    finalPageUrl.password !== '' ||
    finalPageUrl.hash !== ''
  ) {
    fail(`Version page redirected outside the official site: ${page.finalUrl}`);
  }
  const bundleUrl = discoverVersionBundleUrl(page.text, page.finalUrl);
  const bundle = await fetchText(bundleUrl, 'text/javascript');
  validateBundleUrl(bundle.finalUrl);
  return {
    pageHtml: page.text,
    pageUrl: page.finalUrl,
    bundle: bundle.text,
    bundleUrl: bundle.finalUrl,
  };
}

function stageFile(targetPath, contents) {
  mkdirSync(dirname(targetPath), { recursive: true });
  const temporaryPath = join(
    dirname(targetPath),
    `.${basename(targetPath)}.${process.pid}.${randomUUID()}.tmp`,
  );
  let descriptor = null;
  try {
    descriptor = openSync(temporaryPath, 'wx', 0o644);
    writeFileSync(descriptor, contents, 'utf8');
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = null;
    return temporaryPath;
  } catch (error) {
    if (descriptor !== null) {
      closeSync(descriptor);
    }
    rmSync(temporaryPath, { force: true });
    throw error;
  }
}

function atomicWrite(targetPath, contents) {
  const temporaryPath = stageFile(targetPath, contents);
  try {
    renameSync(temporaryPath, targetPath);
  } finally {
    rmSync(temporaryPath, { force: true });
  }
}

function commitMetadataFiles(
  releasePath,
  releaseText,
  catalogPath,
  catalogText,
  verify,
) {
  const oldRelease = existsSync(releasePath)
    ? readFileSync(releasePath, 'utf8')
    : null;
  const oldCatalog = readFileSync(catalogPath, 'utf8');
  let releaseTemporary = null;
  let catalogTemporary = null;
  let releaseInstalled = false;
  let catalogInstalled = false;

  try {
    releaseTemporary = stageFile(releasePath, releaseText);
    catalogTemporary = stageFile(catalogPath, catalogText);
    renameSync(releaseTemporary, releasePath);
    releaseInstalled = true;
    renameSync(catalogTemporary, catalogPath);
    catalogInstalled = true;
    verify();
  } catch (error) {
    let rollbackError = null;
    if (releaseInstalled || catalogInstalled) {
      try {
        if (oldRelease === null) {
          rmSync(releasePath, { force: true });
        } else {
          atomicWrite(releasePath, oldRelease);
        }
        atomicWrite(catalogPath, oldCatalog);
      } catch (rollback) {
        rollbackError = rollback;
      }
    }
    if (rollbackError) {
      fail(
        `Metadata commit failed (${error.message}) and rollback also failed (${rollbackError.message}).`,
      );
    }
    fail(`Metadata commit failed and was rolled back: ${error.message}`);
  } finally {
    if (releaseTemporary !== null) {
      rmSync(releaseTemporary, { force: true });
    }
    if (catalogTemporary !== null) {
      rmSync(catalogTemporary, { force: true });
    }
  }
}

function processIsAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === 'EPERM';
  }
}

function acquireMetadataLock(metadataDir) {
  mkdirSync(metadataDir, { recursive: true });
  const lockPath = join(metadataDir, '.formal-release-update.lock');

  for (let attempt = 0; attempt < 2; attempt += 1) {
    const token = randomUUID();
    let descriptor = null;
    try {
      descriptor = openSync(lockPath, 'wx', 0o644);
      const payload = JSON.stringify({
        pid: process.pid,
        token,
        started_at: new Date().toISOString(),
      });
      writeFileSync(descriptor, `${payload}\n`, 'utf8');
      fsyncSync(descriptor);
      closeSync(descriptor);
      descriptor = null;
      return () => {
        try {
          const current = JSON.parse(readFileSync(lockPath, 'utf8'));
          if (current.token === token) {
            rmSync(lockPath, { force: true });
          }
        } catch {
          // Never remove a lock that no longer contains this owner's token.
        }
      };
    } catch (error) {
      if (descriptor !== null) {
        closeSync(descriptor);
        rmSync(lockPath, { force: true });
      }
      if (error.code !== 'EEXIST') {
        throw error;
      }

      let existing;
      try {
        existing = JSON.parse(readFileSync(lockPath, 'utf8'));
      } catch {
        fail(
          `Metadata lock ${lockPath} is unreadable. Confirm no updater is running, then remove it.`,
        );
      }
      if (!Number.isSafeInteger(existing.pid) || existing.pid <= 0) {
        fail(
          `Metadata lock ${lockPath} has no valid owner. Confirm no updater is running, then remove it.`,
        );
      }
      if (processIsAlive(existing.pid)) {
        fail(
          `Another formal metadata update is running with PID ${existing.pid}.`,
        );
      }
      fail(
        `Stale metadata lock ${lockPath} belongs to inactive PID ${existing.pid}. ` +
          'Confirm no updater is running, remove exactly this lock file, then rerun.',
      );
    }
  }
  fail(`Could not acquire metadata lock ${lockPath}.`);
}

export async function updateFormalRelease({
  version,
  metadataDir = DEFAULT_METADATA_DIR,
  dryRun = false,
  replace = false,
  bundleFile = null,
  expectChannel = null,
} = {}) {
  assertSafeVersion(version);
  const resolvedMetadataDir = resolve(metadataDir);
  const releaseLock = dryRun
    ? null
    : acquireMetadataLock(resolvedMetadataDir);

  try {
    // Ignore only the requested version during preflight. This lets a
    // byte-identical orphan left between the two atomic renames self-heal,
    // while every other formal release remains strictly validated.
    validateMetadataDirectory(resolvedMetadataDir, null, {
      skipVersion: version,
    });
    if (releaseLock !== null) {
      // Yield once while holding the lock so concurrently started updates
      // observe the owner instead of racing the catalog read/merge.
      await Promise.resolve();
    }

    let source;
    if (bundleFile) {
      source = {
        bundle: readFileSync(resolve(bundleFile), 'utf8'),
        bundleUrl: resolve(bundleFile),
        pageHtml: null,
        pageUrl: null,
      };
    } else {
      source = await fetchFormalReleaseSource(version);
    }
    const release = parseFormalReleaseBundle(source.bundle, version, {
      pageHtml: source.pageHtml,
    });
    if (expectChannel && release.catalog.channel !== expectChannel) {
      fail(
        `Expected ${version} to be ${expectChannel}, but the official site says ${release.catalog.channel}.`,
      );
    }

    const catalogPath = join(resolvedMetadataDir, 'catalog.tsv');
    const releasePath = join(
      resolvedMetadataDir,
      'releases',
      `${version}.tsv`,
    );
    const oldCatalogText = readFileSync(catalogPath, 'utf8');
    const oldCatalogRows = parseCatalogTsv(oldCatalogText, catalogPath, {
      skipVersion: version,
    });
    const newCatalogRows = mergeCatalogRows(oldCatalogRows, release.catalog);
    const newCatalogText = renderCatalogTsv(newCatalogRows);
    const newReleaseText = renderReleaseTsv(release.rows);
    parseReleaseTsv(newReleaseText, version, `generated ${version}.tsv`);

    const oldReleaseText = existsSync(releasePath)
      ? readFileSync(releasePath, 'utf8')
      : null;
    const releaseChanged = oldReleaseText !== newReleaseText;
    const catalogChanged = oldCatalogText !== newCatalogText;
    const existingCatalogRows = oldCatalogRows.filter(
      (row) => row.version === version,
    );
    const catalogRecordChanged =
      existingCatalogRows.length !== 1 ||
      CATALOG_COLUMNS.some(
        (column) =>
          existingCatalogRows[0]?.[column] !== release.catalog[column],
      );
    const replacesDifferentContent =
      (oldReleaseText !== null && releaseChanged) ||
      (existingCatalogRows.length > 0 && catalogRecordChanged);
    if (!dryRun && !replace && replacesDifferentContent) {
      fail(
        `Metadata for ${version} already exists with different content. Review --dry-run, then pass --replace.`,
      );
    }

    if (!dryRun && (releaseChanged || catalogChanged)) {
      commitMetadataFiles(
        releasePath,
        newReleaseText,
        catalogPath,
        newCatalogText,
        () => validateMetadataDirectory(resolvedMetadataDir),
      );
    }

    return {
      version,
      source,
      catalog: release.catalog,
      rows: release.rows,
      releasePath,
      catalogPath,
      releaseText: newReleaseText,
      releaseChanged,
      catalogChanged,
      dryRun,
    };
  } finally {
    releaseLock?.();
  }
}

function usage() {
  return `Usage:
  node scripts/update-formal-release.mjs update <version> [options]
  node scripts/update-formal-release.mjs validate [version] [options]

Options:
  --dry-run              Parse and print the generated manifest without writing
  --replace              Replace different metadata for an existing version
  --metadata-dir <path>  Override metadata/v2 (useful for tests)
  --bundle-file <path>   Parse a saved official version bundle instead of fetching
  --expect-channel <LTS|STS>
                         Assert the channel reported by the official site
  -h, --help             Show this help

The updater changes only metadata/v2. It never updates versions.txt or versions/.
`;
}

function parseCli(argv) {
  if (argv.length === 0 || argv.includes('-h') || argv.includes('--help')) {
    return { help: true };
  }
  const command = argv.shift();
  if (command !== 'update' && command !== 'validate') {
    fail(`Unknown command ${command}.`);
  }

  let version = null;
  if (argv[0] && !argv[0].startsWith('-')) {
    version = argv.shift();
    assertSafeVersion(version);
  }
  if (command === 'update' && !version) {
    fail('update requires a version.');
  }

  const options = {
    command,
    version,
    metadataDir: DEFAULT_METADATA_DIR,
    dryRun: false,
    replace: false,
    bundleFile: null,
    expectChannel: null,
  };
  while (argv.length > 0) {
    const option = argv.shift();
    if (option === '--dry-run') {
      options.dryRun = true;
    } else if (option === '--replace') {
      options.replace = true;
    } else if (option === '--metadata-dir') {
      const value = argv.shift();
      if (!value) {
        fail('--metadata-dir requires a path.');
      }
      options.metadataDir = resolve(value);
    } else if (option === '--bundle-file') {
      const value = argv.shift();
      if (!value) {
        fail('--bundle-file requires a path.');
      }
      options.bundleFile = resolve(value);
    } else if (option === '--expect-channel') {
      const value = argv.shift();
      if (value !== 'LTS' && value !== 'STS') {
        fail('--expect-channel must be LTS or STS.');
      }
      options.expectChannel = value;
    } else {
      fail(`Unknown option ${option}.`);
    }
  }
  if (command === 'validate' && (options.dryRun || options.replace)) {
    fail('validate does not accept --dry-run or --replace.');
  }
  if (command === 'validate' && (options.bundleFile || options.expectChannel)) {
    fail('validate does not accept source options.');
  }
  return options;
}

async function main() {
  const [nodeMajor, nodeMinor] = process.versions.node
    .split('.')
    .slice(0, 2)
    .map((part) => Number.parseInt(part, 10));
  if (nodeMajor < 18 || (nodeMajor === 18 && nodeMinor < 1)) {
    fail(`Node.js 18.1 or newer is required; found ${process.versions.node}.`);
  }
  const options = parseCli(process.argv.slice(2));
  if (options.help) {
    process.stdout.write(usage());
    return;
  }
  if (options.command === 'validate') {
    const result = validateMetadataDirectory(
      options.metadataDir,
      options.version,
    );
    process.stdout.write(
      `Validated ${result.versions} formal release(s), ${result.assets} SDK asset(s).\n`,
    );
    return;
  }

  const result = await updateFormalRelease(options);
  if (result.dryRun) {
    process.stdout.write(
      `# ${result.catalog.version}\t${result.catalog.channel}\t${result.catalog.display_name}\t${result.catalog.published_at}\n`,
    );
    process.stdout.write(`# assets: ${result.rows.length}\n`);
    process.stdout.write(`# source: ${result.source.bundleUrl}\n`);
    process.stdout.write(`# output: ${result.releasePath}\n`);
    process.stdout.write(result.releaseText);
    return;
  }
  const state =
    result.releaseChanged || result.catalogChanged ? 'Updated' : 'Unchanged';
  process.stdout.write(
    `${state} ${result.version} (${result.catalog.channel}, ${result.rows.length} SDK assets).\n`,
  );
  process.stdout.write(`${result.releasePath}\n${result.catalogPath}\n`);
}

function comparableRealpath(path) {
  let normalized = realpathSync.native(resolve(path));
  if (process.platform === 'win32') {
    normalized = normalized.toLowerCase();
  }
  return normalized;
}

let invokedAsMain = false;
if (process.argv[1]) {
  try {
    invokedAsMain =
      comparableRealpath(process.argv[1]) === comparableRealpath(SCRIPT_PATH);
  } catch {
    invokedAsMain = false;
  }
}
if (invokedAsMain) {
  main().catch((error) => {
    const detail =
      error instanceof MetadataError ? error.message : `${error.name}: ${error.message}`;
    process.stderr.write(`error: ${detail}\n`);
    process.stderr.write(
      'If the official page changed, use the cjman-formal-release-metadata Skill fallback.\n',
    );
    process.exitCode = 1;
  });
}
