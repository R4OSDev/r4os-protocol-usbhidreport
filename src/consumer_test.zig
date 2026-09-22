const std = @import("std");
const t = std.testing;
const a = @import("r4os").abi;
const decode = @import("consumer.zig").decode;
pub fn check(parse: anytype) !void {
    // Two absolute variable controls, a disjoint output and a second report
    // with an array selector. Global Push/Pop must restore the first ID.
    const descriptor = [_]u8{ 0x05,0x0c,0x09,0x01,0xa1,0x01,0x85,1,
        0x15,0,0x25,1,0x75,1,0x95,2,0x09,0x6f,0x09,0x70,0x81,2,
        0x75,8,0x95,1,0x91,1, // output never shifts subsequent input
        0xa4,0x85,2,0x15,0,0x26,0xff,0x03,0x19,0,0x2a,0xff,0x03,0x75,16,0x95,1,0x81,0,0xb4,
        0x75,6,0x95,1,0x81,1,0xc0 };
    var summary = parse(&descriptor);
    try t.expect(summary.parsed == 1 and summary.malformed == 0 and summary.input_bits[1] == 8 and summary.input_bits[2] == 16);
    var op: a.HidConsumerOp = .{ .summary_address = @intFromPtr(&summary) };
    try t.expectEqual(@as(i32, 0), decode(&op)); try t.expect(op.capabilities == 3 and op.pressed == 0 and op.report_id == 0xffffffff);
    op.report_len = 2; op.report[0] = 1; op.report[1] = 1;
    try t.expectEqual(@as(i32, 0), decode(&op)); try t.expect(op.pressed == 1 and op.report_id == 1);
    op.report[1] = 2; try t.expectEqual(@as(i32, 0), decode(&op)); try t.expectEqual(@as(u32, 2), op.pressed);
    op.report[1] = 0; try t.expectEqual(@as(i32, 0), decode(&op)); try t.expectEqual(@as(u32, 0), op.pressed);
    op.report[0] = 2; op.report_len = 3; op.report[1] = 0x70;
    try t.expectEqual(@as(i32, 0), decode(&op)); try t.expect(op.pressed == 2 and op.report_id == 2);
    op.report_len = 2; const old = op; try t.expectEqual(@as(i32, -2), decode(&op)); try t.expectEqualDeep(old, op);
    op.report[0] = 15; try t.expectEqual(@as(i32, 0), decode(&op)); try t.expect(op.pressed == 0 and op.report_id == 0xffffffff);
    // Unsupported IDs, stack underflow and truncation cannot produce keys.
    for ([_][]const u8{ &.{0x85,16}, &.{0xb4}, &.{0x05} }) |bad| {
        summary = parse(bad); try t.expect(summary.malformed != 0);
        try t.expectEqual(@as(i32, -2), decode(&op));
    }
    summary = parse(&.{0x05,0x0c,0x15,0,0x25,1,0x75,8,0x95,1,0x09,0x6f,0x81,6});
    op.report_len = 1; op.report[0] = 1;
    try t.expectEqual(@as(i32, 0), decode(&op)); try t.expect(op.capabilities == 0 and op.pressed == 0);
}
