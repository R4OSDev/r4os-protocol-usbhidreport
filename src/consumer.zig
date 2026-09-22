// Consumer Control semantics stay in the external HID protocol owner.
const a = @import("r4os").abi;
fn control(item: u32) u32 { return switch (item) { 0x6f => 1, 0x70 => 2, else => 0 }; }
fn usage(field: a.HidReportField, index: u32, repeat: bool) ?u32 {
    if (field.usage_count != 0 and (field.usage_min == field.usage_max or field.usage_count > 1))
        return if (index < field.usage_count) field.usages[index] else if (repeat) field.usages[field.usage_count - 1] else null;
    if (field.usage_min > field.usage_max or index > field.usage_max - field.usage_min) return null;
    return field.usage_min + index;
}
fn bits(data: []const u8, offset: usize, width: u8) ?u32 {
    if (width == 0 or width > 32 or offset + width > data.len * 8) return null;
    var value: u32 = 0;
    for (0..width) |i| value |= @as(u32, (data[(offset + i) / 8] >> @as(u3, @intCast((offset + i) % 8))) & 1) << @as(u5, @intCast(i));
    return value;
}
pub fn decode(op: *a.HidConsumerOp) i32 {
    if (op.version != 1 or op.size < @sizeOf(a.HidConsumerOp) or op.report_len > op.report.len or op.summary_address == 0 or
        op.summary_address % @alignOf(a.HidReportSummary) != 0) return -2;
    const summary: *const a.HidReportSummary = @ptrFromInt(op.summary_address);
    if (summary.parsed != 1 or summary.malformed != 0 or summary.field_count > summary.fields.len or summary.has_report_id > 1) return -2;
    const id: u32 = if (summary.has_report_id == 1 and op.report_len != 0) op.report[0] else 0;
    const skip: usize = summary.has_report_id;
    var capability: u32 = 0; var pressed: u32 = 0; var matched = false;
    for (summary.fields[0..summary.field_count]) |field| {
        if (field.kind != a.hid_report_kind_input or field.usage_page != 0x0c or field.constant != 0 or field.relative != 0) continue;
        if (field.report_id >= 16 or field.bit_size == 0 or field.bit_size > 32 or field.count == 0 or
            field.usage_count > field.usages.len or field.logical_min < 0 or field.logical_max < field.logical_min or
            @as(u32, field.bit_offset) + @as(u32, field.bit_size) * field.count > summary.input_bits[field.report_id]) return -2;
        if (field.variable != 0 and (field.logical_min != 0 or field.logical_max != 1)) continue;
        if (field.variable != 0) {
            for (0..field.count) |index| capability |= control(usage(field, @intCast(index), true) orelse continue);
        } else {
            if (field.usage_count > 1) {
                for (field.usages[0..field.usage_count]) |item| capability |= control(item);
            } else {
                if (field.usage_min <= 0x6f and field.usage_max >= 0x6f) capability |= 1;
                if (field.usage_min <= 0x70 and field.usage_max >= 0x70) capability |= 2;
            }
        }
        if (op.report_len == 0 or id != field.report_id) continue;
        if (op.report_len < skip + (@as(usize, summary.input_bits[field.report_id]) + 7) / 8) return -2;
        matched = true;
        for (0..field.count) |index| {
            const raw = bits(op.report[skip..op.report_len], field.bit_offset + index * field.bit_size, field.bit_size) orelse return -2;
            if (raw < field.logical_min or raw > field.logical_max) {
                if (field.flags & 0x40 != 0) continue;
                return -2;
            }
            const item = if (field.variable != 0) blk: {
                if (raw == 0) continue;
                break :blk usage(field, @intCast(index), true) orelse continue;
            } else usage(field, raw - @as(u32, @intCast(field.logical_min)), false) orelse continue;
            pressed |= control(item);
        }
    }
    op.capabilities = capability; op.pressed = pressed;
    op.report_id = if (matched) id else 0xffffffff;
    return 0;
}
