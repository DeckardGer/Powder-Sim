@group(0) @binding(0) var<storage, read_write> cells: array<u32>;
@group(0) @binding(1) var<storage, read_write> pending: array<u32>;

@compute @workgroup_size(256)
fn main(@builtin(global_invocation_id) id: vec3u) {
    let idx = id.x;
    if idx >= arrayLength(&cells) { return; }

    let p = pending[idx];
    if (p & 0x80000000u) != 0u {
        let value = p & 0x7FFFFFFFu;
        // value == 0: eraser — always overwrite
        // value != 0: particle — only write to empty cells
        if value == 0u || (cells[idx] & 0xFFu) == 0u {
            cells[idx] = value;
        }
        pending[idx] = 0u;
    }
}
