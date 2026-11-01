//! Body-at-rest encryption: XChaCha20-Poly1305, one key, one nonce per body.
//!
//! Bodies are the sensitive part of mail, so the on-disk copy is sealed rather
//! than merely chmodded. The key lives next to the cache with mode 0600, which
//! is the same trust boundary as the password file; the point is that a stray
//! backup, a synced folder, or a shared machine does not hand out prose.

const std = @import("std");
const assert = std.debug.assert;

pub const key_len = 32;
pub const nonce_len = 24;
pub const tag_len = 16;
pub const overhead = nonce_len + tag_len;

pub const Error = error{ TooSmall, Corrupt };

pub const Key = [key_len]u8;
pub const Nonce = [nonce_len]u8;

/// Writes `nonce || ciphertext || tag` into `out` (which must be at least
/// `overhead + plaintext.len` bytes) and returns the sealed slice.
pub fn seal(key: Key, nonce: Nonce, plaintext: []const u8, out: []u8) Error![]const u8 {
    if (out.len < overhead + plaintext.len) return error.TooSmall;

    const aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
    @memcpy(out[0..nonce_len], &nonce);

    var tag: [tag_len]u8 = undefined;
    aead.encrypt(
        out[nonce_len..][0..plaintext.len],
        &tag,
        plaintext,
        "",
        nonce,
        key,
    );
    @memcpy(out[nonce_len + plaintext.len ..][0..tag_len], &tag);
    return out[0 .. overhead + plaintext.len];
}

/// Opens `sealed` into `out` (at least `sealed.len - overhead` bytes).
pub fn open(key: Key, sealed: []const u8, out: []u8) Error![]const u8 {
    if (sealed.len < overhead) return error.Corrupt;

    const aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
    const nonce: Nonce = sealed[0..nonce_len].*;
    const ciphertext = sealed[nonce_len .. sealed.len - tag_len];
    const tag = sealed[sealed.len - tag_len ..][0..tag_len].*;
    if (out.len < ciphertext.len) return error.TooSmall;

    aead.decrypt(
        out[0..ciphertext.len],
        ciphertext,
        tag,
        "",
        nonce,
        key,
    ) catch return error.Corrupt;
    return out[0..ciphertext.len];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn test_key() Key {
    var key: Key = undefined;
    for (&key, 0..) |*byte, index| byte.* = @intCast(index);
    return key;
}

test "sealed: round-trip keeps the text" {
    const key = test_key();
    const nonce: Nonce = @splat(7);
    const text = "Hola, mundo. Cifrado en reposo.";

    var sealed_buffer: [256]u8 = undefined;
    const sealed = try seal(key, nonce, text, &sealed_buffer);
    try testing.expectEqual(text.len + overhead, sealed.len);

    var plain_buffer: [256]u8 = undefined;
    const plain = try open(key, sealed, &plain_buffer);
    try testing.expectEqualStrings(text, plain);
}

test "sealed: the ciphertext does not contain the plaintext" {
    const key = test_key();
    const nonce: Nonce = @splat(1);
    var sealed_buffer: [128]u8 = undefined;
    const sealed = try seal(key, nonce, "SECRET-MARKER", &sealed_buffer);
    try testing.expect(std.mem.indexOf(u8, sealed, "SECRET-MARKER") == null);
}

test "sealed: a wrong key or a flipped byte is Corrupt" {
    const key = test_key();
    const nonce: Nonce = @splat(2);
    var sealed_buffer: [64]u8 = undefined;
    const sealed = try seal(key, nonce, "body", &sealed_buffer);

    var wrong = key;
    wrong[0] ^= 0xff;
    var plain: [64]u8 = undefined;
    try testing.expectError(error.Corrupt, open(wrong, sealed, &plain));

    var tampered = sealed_buffer;
    tampered[nonce_len] ^= 0x01;
    try testing.expectError(error.Corrupt, open(key, tampered[0..sealed.len], &plain));

    try testing.expectError(error.Corrupt, open(key, sealed[0..10], &plain));
}

test "sealed: small buffers are refused, not overrun" {
    const key = test_key();
    var tiny: [4]u8 = undefined;
    try testing.expectError(error.TooSmall, seal(key, @splat(0), "abc", &tiny));
    var sealed_buffer: [64]u8 = undefined;
    const sealed = try seal(key, @splat(0), "abcdef", &sealed_buffer);
    var small: [2]u8 = undefined;
    try testing.expectError(error.TooSmall, open(key, sealed, &small));
}
