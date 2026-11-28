import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { CborError, decodeCbor, decodeCborPrefix } from '../src/cbor.js';
import { cbor, cmap } from './helpers/fake-appattest.js';

const hex = (h: string) => Buffer.from(h.replace(/\s+/g, ''), 'hex');
const refuses = (bytes: Buffer, message: string, limits = {}) =>
  assert.throws(() => decodeCbor(bytes, limits), (e: unknown) => e instanceof CborError && e.message === message);

describe('CBOR decoder: accepted data (RFC 8949 Appendix A vectors)', () => {
  test('unsigned and negative integers at each head width', () => {
    assert.equal(decodeCbor(hex('00')), 0);
    assert.equal(decodeCbor(hex('17')), 23);
    assert.equal(decodeCbor(hex('1818')), 24);
    assert.equal(decodeCbor(hex('1903e8')), 1000);
    assert.equal(decodeCbor(hex('1a000f4240')), 1000000);
    assert.equal(decodeCbor(hex('1b000000e8d4a51000')), 1000000000000);
    assert.equal(decodeCbor(hex('20')), -1);
    assert.equal(decodeCbor(hex('3863')), -100);
    assert.equal(decodeCbor(hex('26')), -7);
  });
  test('byte and text strings', () => {
    assert.deepEqual(decodeCbor(hex('4401020304')), Buffer.from([1, 2, 3, 4]));
    assert.deepEqual(decodeCbor(hex('40')), Buffer.alloc(0));
    assert.equal(decodeCbor(hex('6449455446')), 'IETF');
    assert.equal(decodeCbor(hex('62c3bc')), 'ü');
  });
  test('arrays and maps (maps decode to Map, int and text keys)', () => {
    assert.deepEqual(decodeCbor(hex('83010203')), [1, 2, 3]);
    const m = decodeCbor(hex('a201020304')) as Map<number, number>;
    assert.ok(m instanceof Map);
    assert.deepEqual([...m], [[1, 2], [3, 4]]);
    const t = decodeCbor(cbor(cmap(['a', 1], [-2, Buffer.from('x')]))) as Map<string | number, unknown>;
    assert.equal(t.get('a'), 1);
    assert.deepEqual(t.get(-2), Buffer.from('x'));
  });
  test('a map key named __proto__ is plain data, not a prototype', () => {
    const m = decodeCbor(cbor(cmap(['__proto__', 1]))) as Map<string, number>;
    assert.equal(m.get('__proto__'), 1);
    assert.equal(({} as Record<string, unknown>).polluted, undefined);
  });
  test('round-trips the test encoder within the limits', () => {
    const v = cmap(['fmt', 'apple-appattest'], ['attStmt', cmap(['x5c', [Buffer.alloc(300, 1), Buffer.alloc(70000 % 9000, 2)]])], ['n', -70000]);
    const out = decodeCbor(cbor(v)) as Map<string, unknown>;
    assert.equal(out.get('fmt'), 'apple-appattest');
    assert.equal(out.get('n'), -70000);
  });
  test('prefix decode returns the end offset, for authData', () => {
    const bytes = Buffer.concat([Buffer.alloc(3), cbor(cmap([1, 2])), Buffer.from([0xff])]);
    const r = decodeCborPrefix(bytes, 3);
    assert.equal(r.end, 3 + 3);
    assert.ok(r.value instanceof Map);
    assert.throws(() => decodeCborPrefix(bytes, bytes.length), CborError);
    assert.throws(() => decodeCborPrefix(bytes, -1), CborError);
  });
});

describe('CBOR decoder: refusals (Fry #246 rec. 5)', () => {
  test('indefinite lengths', () => {
    refuses(hex('5f42010243030405ff'), 'indefinite length'); // bstr
    refuses(hex('7f657374726561646d696e67ff'), 'indefinite length'); // tstr
    refuses(hex('9f018202039f0405ffff'), 'indefinite length'); // array
    refuses(hex('bf61610161629f0203ffff'), 'indefinite length'); // map
  });
  test('reserved additional info 28-30', () => {
    for (const b of ['1c', '1d', '1e', '3c', '5c', '7d', '9e', 'bc']) refuses(hex(b), 'reserved');
  });
  test('tags, floats, simple values, booleans, null, undefined, break', () => {
    refuses(hex('c11a514b67b0'), 'tag');
    refuses(hex('d8184100'), 'tag');
    for (const b of ['f4', 'f5', 'f6', 'f7', 'f93c00', 'fa47c35000', 'fb3ff199999999999a', 'ff', 'e0', 'f820']) {
      refuses(hex(b), 'simple/float');
    }
  });
  test('non-minimal heads at every width', () => {
    refuses(hex('1817'), 'non-minimal');
    refuses(hex('1900ff'), 'non-minimal');
    refuses(hex('1a0000ffff'), 'non-minimal');
    refuses(hex('1b00000000ffffffff'), 'non-minimal');
    refuses(hex('5801' + '00'), 'non-minimal');
    refuses(hex('980101'), 'non-minimal');
    refuses(hex('3817'), 'non-minimal');
  });
  test('integers beyond the safe range', () => {
    refuses(hex('1b0020000000000000'), 'integer range');
    refuses(hex('1bffffffffffffffff'), 'integer range');
    refuses(hex('3bffffffffffffffff'), 'integer range');
    refuses(hex('3b001fffffffffffff'), 'integer range'); // -1 - (2^53-1) is not safe
    assert.equal(decodeCbor(hex('1b001fffffffffffff')), Number.MAX_SAFE_INTEGER);
  });
  test('trailing bytes after the item', () => {
    refuses(hex('0000'), 'trailing bytes');
    refuses(Buffer.concat([cbor(cmap(['a', 1])), Buffer.from([0])]), 'trailing bytes');
  });
  test('truncated items and lengths beyond the input', () => {
    for (const b of ['18', '19ff', '1a0000ff', '1b00000000ff', '4401', '62c3', '8201', 'a101', '5a00010000']) {
      refuses(hex(b), 'truncated');
    }
  });
  test('duplicate map keys, including int keys', () => {
    refuses(cbor(cmap(['fmt', 'a'], ['fmt', 'b'])), 'duplicate map key');
    refuses(cbor(cmap([1, 2], [1, 2])), 'duplicate map key');
    // 1 and "1" are different keys.
    assert.equal((decodeCbor(cbor(cmap([1, 2], ['1', 2]))) as Map<unknown, unknown>).size, 2);
  });
  test('map keys that are not text or int', () => {
    refuses(cbor(cmap([Buffer.from('k'), 1])), 'map key type');
    refuses(cbor(cmap([[1], 1])), 'map key type');
  });
  test('invalid UTF-8 text (overlong, surrogate, truncated, stray continuation)', () => {
    for (const b of ['62c0af', '63eda080', '61c3', '6180', '64f4908080']) refuses(hex(b), 'utf8');
  });
  test('nesting deeper than 4 containers', () => {
    assert.deepEqual(decodeCbor(hex('81818181' + '00')), [[[[0]]]]);
    refuses(hex('8181818181' + '00'), 'depth');
    refuses(hex('a1' + '01' + 'a1' + '01' + 'a1' + '01' + 'a1' + '01' + 'a1' + '0100'), 'depth');
    refuses(hex('8100'), 'depth', { maxDepth: 0 });
  });
  test('more than 16 items in a container, before reading them', () => {
    assert.equal((decodeCbor(cbor(Array.from({ length: 16 }, () => 0))) as unknown[]).length, 16);
    refuses(cbor(Array.from({ length: 17 }, () => 0)), 'too many items');
    refuses(hex('9bffffffffffffffff'), 'integer range');
    refuses(hex('9a7fffffff'), 'too many items');
    refuses(hex('ba7fffffff'), 'too many items');
  });
  test('total size cap and empty input', () => {
    refuses(Buffer.alloc(0), 'empty');
    refuses(cbor(Buffer.alloc(16 * 1024)), 'too large');
    refuses(cbor(Buffer.alloc(10)), 'too large', { maxBytes: 8 });
  });
});

describe('CBOR decoder fuzz', () => {
  test('20,000 random and mutated inputs: only values or CborError, never another exception', () => {
    const seed = crypto.createHash('sha256').update('aerodj cbor fuzz').digest();
    let state = seed.readUInt32BE(0) || 1;
    const rand = () => {
      // xorshift32, deterministic so a failure reproduces.
      state ^= state << 13;
      state ^= state >>> 17;
      state ^= state << 5;
      return (state >>> 0) / 0x100000000;
    };
    const base = cbor(
      cmap(
        ['fmt', 'apple-appattest'],
        ['attStmt', cmap(['x5c', [Buffer.alloc(40, 7), Buffer.alloc(20, 9)]], ['receipt', Buffer.alloc(8)])],
        ['authData', Buffer.alloc(60, 3)],
      ),
    );
    let decoded = 0;
    for (let i = 0; i < 20_000; i += 1) {
      let input: Buffer;
      if (i % 2 === 0) {
        input = Buffer.from(base);
        const flips = 1 + Math.floor(rand() * 4);
        for (let f = 0; f < flips; f += 1) input[Math.floor(rand() * input.length)] = Math.floor(rand() * 256);
        if (rand() < 0.2) input = input.subarray(0, Math.floor(rand() * input.length));
      } else {
        input = Buffer.from(Array.from({ length: 1 + Math.floor(rand() * 48) }, () => Math.floor(rand() * 256)));
      }
      try {
        decodeCbor(input);
        decoded += 1;
      } catch (e) {
        assert.ok(e instanceof CborError, `non-CborError on ${input.toString('hex')}: ${String(e)}`);
      }
    }
    assert.ok(decoded > 0);
  });
});
