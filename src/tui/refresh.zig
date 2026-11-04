//! A background refresh: the only thread zmail ever spawns.
//!
//! The transport is blocking (TLS over a socket, with bounded timeouts), so
//! concurrency here is one worker thread and one atomic flag: the UI keeps
//! drawing cached mail and a spinner while the worker fetches. When the flag
//! turns to `done`, the session joins the thread and swaps the results into
//! the store, so the store is only ever touched by the UI thread.
//!
//! Process-boundary plumbing, like `launch.zig`: excluded from coverage and
//! exercised end to end (the fake server and a real pty run).

const std = @import("std");
const core = @import("core");

const Message = core.message.Message;
const Mailbox = core.mailbox.Mailbox;
const AccountId = core.id.AccountId;

pub const max_accounts: u8 = core.app_max_accounts;

pub const Source = struct {
    id: AccountId,
    mail: core.mail_port.Mail,
};

pub const State = enum(u8) { running, done };

pub const Job = struct {
    thread: std.Thread = undefined,
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@backingInt(State.done)),
    sources: []const Source = &.{},
    mailbox: Mailbox = .inbox,
    /// One slot per account: the worker writes each account's envelopes into
    /// its own region so the UI never reads a half-written mailbox.
    buffer: []Message = &.{},
    offsets: [max_accounts]u32 = @splat(0),
    counts: [max_accounts]u32 = @splat(0),
    /// Per account: did the fetch succeed? A failed account keeps its old mail.
    ok: [max_accounts]bool = @splat(false),
    failures: u32 = 0,

    /// Starts the worker. A thread that cannot be spawned is reported as a
    /// finished job with one failure, so the caller has a single code path.
    pub fn start(job: *Job, sources: []const Source, mailbox: Mailbox, buffer: []Message) void {
        job.sources = sources;
        job.mailbox = mailbox;
        job.buffer = buffer;
        job.failures = 0;
        job.counts = @splat(0);
        job.offsets = @splat(0);
        job.ok = @splat(false);
        job.state.store(@backingInt(State.running), .release);
        job.thread = std.Thread.spawn(.{}, run, .{job}) catch {
            job.failures = 1;
            job.state.store(@backingInt(State.done), .release);
            return;
        };
    }

    pub fn finished(job: *const Job) bool {
        return job.state.load(.acquire) == @backingInt(State.done);
    }

    pub fn join(job: *Job) void {
        job.thread.join();
    }

    fn run(job: *Job) void {
        var offset: u32 = 0;
        for (job.sources, 0..) |source, index| {
            job.offsets[index] = offset;
            const slice = job.buffer[offset..];
            const count = source.mail.fetch(job.mailbox, slice) catch {
                job.failures += 1;
                continue;
            };
            job.ok[index] = true;
            job.counts[index] = count;
            offset += count;
        }
        job.state.store(@backingInt(State.done), .release);
    }
};

/// One message's body, fetched off the loop.
///
/// The same shape as `Job`, and for the same reason: the transport blocks, the reader
/// must not. The worker writes into the session's buffer and turns the flag to `done`;
/// the session joins it on a later tick and parses the bytes itself, so the body, the
/// wrapped lines and the links are only ever built by the thread that draws them.
pub const BodyRequest = struct {
    account: AccountId,
    mailbox: Mailbox,
    id: core.id.MessageId,
    mail: core.mail_port.Mail,
};

pub const BodyJob = struct {
    thread: std.Thread = undefined,
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@backingInt(State.done)),
    request: BodyRequest = undefined,
    buffer: []u8 = &.{},
    len: u32 = 0,
    /// False when the server refused, or when the bytes did not fit: either way the
    /// reader says so instead of showing half a message.
    ok: bool = false,

    pub fn start(job: *BodyJob, request: BodyRequest, buffer: []u8) void {
        job.request = request;
        job.buffer = buffer;
        job.len = 0;
        job.ok = false;
        job.state.store(@backingInt(State.running), .release);
        job.thread = std.Thread.spawn(.{}, runBody, .{job}) catch {
            job.state.store(@backingInt(State.done), .release);
            return;
        };
    }

    pub fn finished(job: *const BodyJob) bool {
        return job.state.load(.acquire) == @backingInt(State.done);
    }

    pub fn join(job: *BodyJob) void {
        job.thread.join();
    }

    pub fn bytes(job: *const BodyJob) []const u8 {
        return job.buffer[0..job.len];
    }

    fn runBody(job: *BodyJob) void {
        const request = job.request;
        if (request.mail.fetch_raw(request.mailbox, request.id, job.buffer)) |raw| {
            job.len = @intCast(raw.len);
            job.ok = true;
        } else |_| {}
        job.state.store(@backingInt(State.done), .release);
    }
};

/// One picture the message points at, fetched off the loop.
///
/// Only ever started when the reader has been told to show pictures: a receipt full of
/// tracking pixels is not something to download because a key was pressed to open it.
pub const ImageFetch = *const fn (context: *anyopaque, url: []const u8, out: []u8) ?[]const u8;

pub const ImageJob = struct {
    thread: std.Thread = undefined,
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@backingInt(State.done)),
    fetch: ImageFetch = undefined,
    context: *anyopaque = undefined,
    url: core.text.Text(core.limits.url_max) = .{},
    buffer: []u8 = &.{},
    len: u32 = 0,
    ok: bool = false,

    pub fn start(
        job: *ImageJob,
        fetch: ImageFetch,
        context: *anyopaque,
        url: []const u8,
        buffer: []u8,
    ) void {
        job.fetch = fetch;
        job.context = context;
        job.url.set(url);
        job.buffer = buffer;
        job.len = 0;
        job.ok = false;
        job.state.store(@backingInt(State.running), .release);
        job.thread = std.Thread.spawn(.{}, runImage, .{job}) catch {
            job.state.store(@backingInt(State.done), .release);
            return;
        };
    }

    pub fn finished(job: *const ImageJob) bool {
        return job.state.load(.acquire) == @backingInt(State.done);
    }

    pub fn join(job: *ImageJob) void {
        job.thread.join();
    }

    fn runImage(job: *ImageJob) void {
        if (job.fetch(job.context, job.url.slice(), job.buffer)) |bytes| {
            job.len = @intCast(bytes.len);
            job.ok = true;
        }
        job.state.store(@backingInt(State.done), .release);
    }
};
