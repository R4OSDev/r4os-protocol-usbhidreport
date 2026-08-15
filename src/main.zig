const r4os = @import("r4os");

const MAX_FIELDS: usize = r4os.abi.hid_report_max_fields;
const MAX_FIELD_USAGES: usize = r4os.abi.hid_report_max_field_usages;

const GlobalState = struct {
    usage_page: u32 = 0,
    logical_min: i32 = 0,
    logical_max: i32 = 0,
    report_size: u8 = 0,
    report_count: u8 = 0,
    report_id: u8 = 0,
};

const LocalState = struct {
    usage: u32 = 0,
    usages: [MAX_FIELD_USAGES]u32 = .{0} ** MAX_FIELD_USAGES,
    usage_count: u8 = 0,
    usage_min: u32 = 0,
    usage_max: u32 = 0,
    have_usage: bool = false,
    have_usage_min: bool = false,
    have_usage_max: bool = false,

    fn clear(self: *LocalState) void {
        self.* = .{};
    }

    fn addUsage(self: *LocalState, usage: u32) void {
        self.usage = usage;
        self.have_usage = true;
        if (self.usage_count < MAX_FIELD_USAGES) {
            self.usages[@intCast(self.usage_count)] = usage;
            self.usage_count += 1;
        }
    }
};

comptime {
    asm (r4os.r4dev.protocolEntriesAsm("usbhidr_init", "usbhidr_shutdown", "usbhidr_query", "usbhidr_dispatch"));
}

export fn usbhidr_init(api: *const r4os.r4dev.ProtocolApi) callconv(.c) i32 {
    var ctx = r4os.r4dev.ProtocolContext.init(api);
    ctx.logInfo("HIDREPORT.R4P init");
    _ = ctx.registerRole("usb.hid_report", .usb, 0);
    _ = ctx.setStatus(.active, "HID report parser R4P active");
    return 0;
}

export fn usbhidr_shutdown() callconv(.c) i32 {
    return 0;
}

export fn usbhidr_query(out: *r4os.abi.ProtocolStatus) callconv(.c) i32 {
    out.* = .{
        .state = @intFromEnum(r4os.abi.ProtocolState.active),
        .flags = 0,
        .last_error = 0,
        .reserved = 0,
        .note = note("HID report parser R4P ready"),
    };
    return 0;
}

export fn usbhidr_dispatch(op: u32, in_buffer: *const r4os.abi.ProtocolBuffer, out_buffer: *r4os.abi.ProtocolBuffer) callconv(.c) i32 {
    _ = out_buffer;
    const request = requestFromBuffer(in_buffer) orelse return -2;
    switch (op) {
        r4os.abi.hid_report_op_parse => parseOp(request),
        r4os.abi.hid_report_op_self_test => selfTestOp(request),
        else => return -4,
    }
    return request.result;
}

fn parseOp(op: *r4os.abi.HidReportOp) void {
    if (op.descriptor_len > op.descriptor.len) {
        op.result = r4os.abi.hid_report_result_bad_length;
        return;
    }
    op.summary = parseDescriptor(op.descriptor[0..@intCast(op.descriptor_len)]);
    op.result = r4os.abi.hid_report_result_ok;
}

fn selfTestOp(op: *r4os.abi.HidReportOp) void {
    const descriptor = [_]u8{
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x01,
        0xA1, 0x00, 0x05, 0x09, 0x19, 0x01, 0x29, 0x03,
        0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01,
        0x81, 0x02, 0x95, 0x01, 0x75, 0x05, 0x81, 0x01,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38,
        0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03,
        0x81, 0x06, 0xC0, 0xC0,
    };
    op.summary = parseDescriptor(descriptor[0..]);
    const ok = op.summary.parsed != 0 and op.summary.malformed == 0 and op.summary.usage_mouse != 0 and op.summary.usage_x != 0 and op.summary.usage_y != 0 and op.summary.usage_wheel != 0 and op.summary.usage_buttons != 0 and op.summary.field_count >= 3;
    op.result = if (ok) r4os.abi.hid_report_result_ok else r4os.abi.hid_report_result_bad_length;
}

fn parseDescriptor(bytes: []const u8) r4os.abi.HidReportSummary {
    var summary: r4os.abi.HidReportSummary = .{
        .parsed = 1,
        .reason_code = r4os.abi.hid_report_reason_parsed,
    };
    var global: GlobalState = .{};
    var local: LocalState = .{};
    var report_id_seen: [16]bool = .{false} ** 16;
    var bit_offsets: [16]u16 = .{0} ** 16;
    var i: usize = 0;
    while (i < bytes.len) {
        const prefix = bytes[i];
        i += 1;
        if (prefix == 0xFE) {
            if (i + 2 > bytes.len) return malformed(summary, r4os.abi.hid_report_reason_truncated_long_item);
            const size = bytes[i];
            i += 2;
            if (i + size > bytes.len) return malformed(summary, r4os.abi.hid_report_reason_truncated_long_payload);
            i += size;
            continue;
        }

        const size_code = prefix & 0x03;
        const data_len: usize = switch (size_code) {
            0 => 0,
            1 => 1,
            2 => 2,
            else => 4,
        };
        if (i + data_len > bytes.len) return malformed(summary, r4os.abi.hid_report_reason_truncated_short_item);
        const typ = (prefix >> 2) & 0x03;
        const tag = (prefix >> 4) & 0x0F;
        const raw = readUnsigned(bytes[i .. i + data_len]);
        const signed = readSigned(bytes[i .. i + data_len]);
        i += data_len;

        switch (typ) {
            0 => {
                const kind: ?u8 = switch (tag) {
                    8 => r4os.abi.hid_report_kind_input,
                    9 => r4os.abi.hid_report_kind_output,
                    11 => r4os.abi.hid_report_kind_feature,
                    else => null,
                };
                if (kind) |field_kind| {
                    addField(&summary, &global, &local, &bit_offsets, &report_id_seen, field_kind, @truncate(raw));
                    local.clear();
                } else if (tag == 10 or tag == 12) {
                    local.clear();
                }
            },
            1 => switch (tag) {
                0 => global.usage_page = raw,
                1 => global.logical_min = signed,
                2 => global.logical_max = signed,
                7 => global.report_size = clampU8(raw),
                8 => {
                    global.report_id = clampU8(raw);
                    summary.has_report_id = 1;
                    markReportId(&summary, &report_id_seen, global.report_id);
                },
                9 => global.report_count = clampU8(raw),
                else => {},
            },
            2 => switch (tag) {
                0 => {
                    local.addUsage(raw);
                    markUsage(&summary, global.usage_page, raw);
                },
                1 => {
                    local.usage_min = raw;
                    local.have_usage_min = true;
                    markUsage(&summary, global.usage_page, raw);
                },
                2 => {
                    local.usage_max = raw;
                    local.have_usage_max = true;
                    markUsage(&summary, global.usage_page, raw);
                },
                else => {},
            },
            else => {},
        }
    }
    summary.input_bits = bit_offsets;
    return summary;
}

fn addField(
    summary: *r4os.abi.HidReportSummary,
    global: *const GlobalState,
    local: *const LocalState,
    bit_offsets: *[16]u16,
    report_id_seen: *[16]bool,
    kind: u8,
    flags: u8,
) void {
    const report_index: usize = if (global.report_id < 16) global.report_id else 0;
    if (global.report_id != 0) markReportId(summary, report_id_seen, global.report_id);
    const count = if (global.report_count == 0) 1 else global.report_count;
    const size = global.report_size;
    const total_bits: u16 = @as(u16, size) * @as(u16, count);
    switch (kind) {
        r4os.abi.hid_report_kind_output => summary.output_fields +|= 1,
        r4os.abi.hid_report_kind_feature => summary.feature_fields +|= 1,
        else => summary.input_fields +|= 1,
    }
    if (summary.field_count < MAX_FIELDS) {
        const idx: usize = @intCast(summary.field_count);
        const usage_min = if (local.have_usage_min) local.usage_min else local.usage;
        const usage_max = if (local.have_usage_max) local.usage_max else if (local.usage_count > 1) local.usages[@intCast(local.usage_count - 1)] else usage_min;
        summary.fields[idx] = .{
            .kind = kind,
            .usage_page = @truncate(global.usage_page),
            .usage_min = usage_min,
            .usage_max = usage_max,
            .usages = local.usages,
            .usage_count = local.usage_count,
            .report_id = global.report_id,
            .bit_offset = bit_offsets[report_index],
            .bit_size = size,
            .count = count,
            .logical_min = global.logical_min,
            .logical_max = global.logical_max,
            .flags = flags,
            .relative = if ((flags & 0x04) != 0) 1 else 0,
            .variable = if ((flags & 0x02) != 0) 1 else 0,
            .constant = if ((flags & 0x01) != 0) 1 else 0,
        };
        summary.field_count += 1;
    }
    bit_offsets[report_index] +|= total_bits;
}

fn markUsage(summary: *r4os.abi.HidReportSummary, usage_page: u32, usage: u32) void {
    if (usage_page == 0x01) {
        switch (usage) {
            0x01 => summary.usage_pointer = 1,
            0x02 => summary.usage_mouse = 1,
            0x06 => summary.usage_keyboard = 1,
            0x30 => summary.usage_x = 1,
            0x31 => summary.usage_y = 1,
            0x38 => summary.usage_wheel = 1,
            else => {},
        }
    } else if (usage_page == 0x09 and usage >= 1) {
        summary.usage_buttons = 1;
    } else if (usage_page == 0x07) {
        summary.usage_keyboard = 1;
    }
}

fn markReportId(summary: *r4os.abi.HidReportSummary, seen: *[16]bool, report_id: u8) void {
    if (report_id >= seen.len) return;
    if (!seen[report_id]) {
        seen[report_id] = true;
        summary.report_ids +|= 1;
    }
}

fn malformed(summary: r4os.abi.HidReportSummary, reason: u16) r4os.abi.HidReportSummary {
    var out = summary;
    out.malformed = 1;
    out.reason_code = reason;
    return out;
}

fn requestFromBuffer(buffer: *const r4os.abi.ProtocolBuffer) ?*r4os.abi.HidReportOp {
    if (buffer.data == null) return null;
    if (buffer.len < @sizeOf(r4os.abi.HidReportOp)) return null;
    return @ptrCast(@alignCast(buffer.data.?));
}

fn readUnsigned(bytes: []const u8) u32 {
    var value: u32 = 0;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) value |= @as(u32, bytes[i]) << @as(u5, @intCast(i * 8));
    return value;
}

fn readSigned(bytes: []const u8) i32 {
    return switch (bytes.len) {
        0 => 0,
        1 => @as(i32, @as(i8, @bitCast(bytes[0]))),
        2 => @as(i32, @as(i16, @bitCast(@as(u16, @intCast(readUnsigned(bytes)))))),
        else => @as(i32, @bitCast(readUnsigned(bytes))),
    };
}

fn clampU8(value: u32) u8 {
    return if (value > 255) 255 else @intCast(value);
}

fn note(comptime text: []const u8) [64]u8 {
    var out: [64]u8 = .{0} ** 64;
    @memcpy(out[0..text.len], text);
    return out;
}
