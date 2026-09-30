// A small, standards-compliant uncompressed ZIP writer. PNGs are already compressed.
const encoder = new TextEncoder();
const crcTable = Uint32Array.from({ length: 256 }, (_, n) => {
  for (let k = 0; k < 8; k++) n = n & 1 ? 0xedb88320 ^ (n >>> 1) : n >>> 1;
  return n >>> 0;
});
function crc32(bytes) {
  let crc = 0xffffffff;
  for (const b of bytes) crc = crcTable[(crc ^ b) & 255] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}
function header(size) {
  const bytes = new Uint8Array(size), view = new DataView(bytes.buffer);
  return { bytes, u16: (offset, value) => view.setUint16(offset, value, true), u32: (offset, value) => view.setUint32(offset, value, true) };
}
export async function createZip(files) {
  const chunks = [], directory = [];
  let offset = 0, directorySize = 0;
  for (const file of files) {
    const name = encoder.encode(file.name), data = new Uint8Array(await file.blob.arrayBuffer()), crc = crc32(data);
    const local = header(30);
    local.u32(0, 0x04034b50); local.u16(4, 20); local.u16(6, 0x800); local.u16(12, 33);
    local.u32(14, crc); local.u32(18, data.length); local.u32(22, data.length); local.u16(26, name.length);
    chunks.push(local.bytes, name, data);
    const central = header(46);
    central.u32(0, 0x02014b50); central.u16(4, 20); central.u16(6, 20); central.u16(8, 0x800); central.u16(14, 33);
    central.u32(16, crc); central.u32(20, data.length); central.u32(24, data.length); central.u16(28, name.length); central.u32(42, offset);
    directory.push(central.bytes, name); directorySize += 46 + name.length;
    offset += 30 + name.length + data.length;
  }
  const end = header(22);
  end.u32(0, 0x06054b50); end.u16(8, files.length); end.u16(10, files.length); end.u32(12, directorySize); end.u32(16, offset);
  return new Blob([...chunks, ...directory, end.bytes], { type: 'application/zip' });
}
