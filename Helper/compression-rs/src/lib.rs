//! macOS replacement for the parts of MassEffectModder's CompressionWrappers library that
//! LegendaryExplorerCore calls (see LegendaryExplorerCore/Compression/*.cs).
//!
//! Return codes follow LZMA SDK conventions, as LEC expects: 0 = OK, 1 = data error,
//! 4 = unsupported, 5 = bad parameter, 7 = output buffer too small.
//!
//! Formats:
//! - LZMA ("SevenZip*"): 5-byte LZMA properties followed by the raw stream, no size field.
//!   The uncompressed size is given by `dst_len`.
//! - Zlib: standard zlib-wrapped deflate.
//! - LZO and LZX are only used by the original-trilogy and Xbox packages, so they report unsupported.
#![allow(non_snake_case, clippy::missing_safety_doc)]

use std::io::{Cursor, Read, Write};
use std::slice;

const SZ_OK: i32 = 0;
const SZ_ERROR_DATA: i32 = 1;
const SZ_ERROR_UNSUPPORTED: i32 = 4;
const SZ_ERROR_PARAM: i32 = 5;
const SZ_ERROR_OUTPUT_EOF: i32 = 7;

unsafe fn input<'a>(ptr: *const u8, len: u32) -> Option<&'a [u8]> {
    (!ptr.is_null()).then(|| slice::from_raw_parts(ptr, len as usize))
}

/// Copies `data` to the caller's buffer and updates its length, or reports that it doesn't fit.
unsafe fn write_output(data: &[u8], dst: *mut u8, dst_len: *mut u32) -> i32 {
    if dst.is_null() || dst_len.is_null() {
        return SZ_ERROR_PARAM;
    }
    if data.len() > *dst_len as usize {
        return SZ_ERROR_OUTPUT_EOF;
    }
    std::ptr::copy_nonoverlapping(data.as_ptr(), dst, data.len());
    *dst_len = data.len() as u32;
    SZ_OK
}

#[no_mangle]
pub unsafe extern "C" fn SevenZipDecompress(src: *const u8, src_len: u32, dst: *mut u8, dst_len: *mut u32) -> i32 {
    let Some(src) = input(src, src_len) else { return SZ_ERROR_PARAM };
    if dst_len.is_null() {
        return SZ_ERROR_PARAM;
    }
    let expected = *dst_len as u64;
    let options = lzma_rs::decompress::Options {
        unpacked_size: lzma_rs::decompress::UnpackedSize::UseProvided(Some(expected)),
        ..Default::default()
    };
    let mut out = Vec::with_capacity(expected as usize);
    match lzma_rs::lzma_decompress_with_options(&mut Cursor::new(src), &mut out, &options) {
        Ok(()) => write_output(&out, dst, dst_len),
        Err(_) => SZ_ERROR_DATA,
    }
}

#[no_mangle]
pub unsafe extern "C" fn SevenZipCompress(_level: i32, src: *const u8, src_len: u32, dst: *mut u8, dst_len: *mut u32) -> i32 {
    let Some(src) = input(src, src_len) else { return SZ_ERROR_PARAM };
    let options = lzma_rs::compress::Options {
        unpacked_size: lzma_rs::compress::UnpackedSize::SkipWritingToHeader,
    };
    let mut out = Vec::new();
    match lzma_rs::lzma_compress_with_options(&mut Cursor::new(src), &mut out, &options) {
        Ok(()) => write_output(&out, dst, dst_len),
        Err(_) => SZ_ERROR_DATA,
    }
}

#[no_mangle]
pub extern "C" fn SevenZipUnpackFile(_archive: *const u16, _output: *const u16, _keep_paths: i32) -> i32 {
    SZ_ERROR_UNSUPPORTED
}

#[no_mangle]
pub unsafe extern "C" fn ZlibDecompress(src: *const u8, src_len: u32, dst: *mut u8, dst_len: *mut u32) -> i32 {
    let Some(src) = input(src, src_len) else { return SZ_ERROR_PARAM };
    if dst_len.is_null() {
        return SZ_ERROR_PARAM;
    }
    let mut out = Vec::with_capacity(*dst_len as usize);
    match flate2::read::ZlibDecoder::new(src).read_to_end(&mut out) {
        Ok(_) => write_output(&out, dst, dst_len),
        Err(_) => SZ_ERROR_DATA,
    }
}

#[no_mangle]
pub unsafe extern "C" fn ZlibCompress(level: i32, src: *const u8, src_len: u32, dst: *mut u8, dst_len: *mut u32) -> i32 {
    let Some(src) = input(src, src_len) else { return SZ_ERROR_PARAM };
    let mut encoder = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::new(level.clamp(0, 9) as u32));
    match encoder.write_all(src).and_then(|_| encoder.finish()) {
        Ok(out) => write_output(&out, dst, dst_len),
        Err(_) => SZ_ERROR_DATA,
    }
}

#[no_mangle]
pub extern "C" fn LZODecompress(_src: *const u8, _src_len: u32, _dst: *mut u8, _dst_len: *mut u32) -> i32 {
    SZ_ERROR_UNSUPPORTED
}

#[no_mangle]
pub extern "C" fn LZOCompress(_src: *const u8, _src_len: u32, _dst: *mut u8, _dst_len: *mut u32) -> i32 {
    SZ_ERROR_UNSUPPORTED
}

#[no_mangle]
pub extern "C" fn LZXDecompress(_src: *const u8, _src_len: u32, _dst: *mut u8, _dst_len: *mut u32) -> i32 {
    SZ_ERROR_UNSUPPORTED
}
