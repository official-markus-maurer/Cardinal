const std = @import("std");

pub const CardinalError = error{
    InitializationFailed,
    InvalidParameter,
    OutOfMemory,
    ResourceNotFound,
    AccessDenied,
    NotSupported,
    Timeout,
    BufferTooSmall,
    IoError,
    Unknown,
};

pub const CardinalErrorCode = enum(c_int) {
    Success = 0,
    InitializationFailed = -1,
    InvalidParameter = -2,
    OutOfMemory = -3,
    ResourceNotFound = -4,
    AccessDenied = -5,
    NotSupported = -6,
    Timeout = -7,
    BufferTooSmall = -8,
    IoError = -9,
    Unknown = -127,
};

pub fn errorToCode(err: anyerror) CardinalErrorCode {
    return switch (err) {
        error.InitializationFailed => .InitializationFailed,
        error.InvalidParameter => .InvalidParameter,
        error.OutOfMemory => .OutOfMemory,
        error.ResourceNotFound => .ResourceNotFound,
        error.AccessDenied => .AccessDenied,
        error.NotSupported => .NotSupported,
        error.Timeout => .Timeout,
        error.BufferTooSmall => .BufferTooSmall,
        error.IoError, error.AccessDenied, error.BrokenPipe, error.SystemResources, error.OperationAborted, error.NotOpenForReading, error.NotOpenForWriting, error.IsDir, error.NotDir, error.FileTooBig, error.NoSpaceLeft, error.DeviceBusy => .IoError,
        else => .Unknown,
    };
}

pub fn codeToError(code: c_int) CardinalError {
    return switch (@as(CardinalErrorCode, @enumFromInt(code))) {
        .Success => unreachable, // Caller should check for success
        .InitializationFailed => error.InitializationFailed,
        .InvalidParameter => error.InvalidParameter,
        .OutOfMemory => error.OutOfMemory,
        .ResourceNotFound => error.ResourceNotFound,
        .AccessDenied => error.AccessDenied,
        .NotSupported => error.NotSupported,
        .Timeout => error.Timeout,
        .BufferTooSmall => error.BufferTooSmall,
        .IoError => error.IoError,
        else => error.Unknown,
    };
}
