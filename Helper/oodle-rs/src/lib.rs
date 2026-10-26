//! Exports the subset of Epic's oo2core API that LegendaryExplorerCore calls (OodleHelper.cs),
//! implemented with the MIT-licensed `oozextract` decoder so Legendary Edition packages can be
//! read on macOS.
//!
//! Only decompression is implemented. The helper saves packages uncompressed, which the games
//! load normally, so `OodleLZ_Compress` reports failure if it is ever called.
use oozextract::Extractor;
use std::slice;

/// Returns the number of bytes written, or 0 on failure (Oodle's convention).
///
/// # Safety
/// `buffer` must point to `buffer_size` readable bytes and `output` to `output_size` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn OodleLZ_Decompress(
    buffer: *const u8,
    buffer_size: i64,
    output: *mut u8,
    output_size: i64,
    _a: u32, _b: u32, _c: u32,
    _d: u64, _e: u64, _f: u64, _g: u64, _h: u64, _i: u64,
    _thread_module: u64,
) -> i32 {
    if buffer.is_null() || output.is_null() || buffer_size <= 0 || output_size <= 0 {
        return 0;
    }
    let input = slice::from_raw_parts(buffer, buffer_size as usize);
    let out = slice::from_raw_parts_mut(output, output_size as usize);
    match Extractor::new().read_from_slice(input, out) {
        Ok(written) if written == out.len() => written as i32,
        _ => 0,
    }
}

#[no_mangle]
pub extern "C" fn OodleLZ_Compress(
    _format: u32, _buffer: *const u8, _buffer_size: i64, _output: *mut u8, _level: u32,
    _u1: u64, _u2: u64, _u3: u64, _u4: u64, _u5: u64,
) -> i32 {
    0
}

/// Oodle's documented worst-case bound: input size plus 274 bytes per 256 KB block.
#[no_mangle]
pub extern "C" fn OodleLZ_GetCompressedBufferSizeNeeded(_format: u8, buffer_size: i64) -> i64 {
    buffer_size + 274 * ((buffer_size + 0x40000 - 1) / 0x40000)
}
