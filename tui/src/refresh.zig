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
