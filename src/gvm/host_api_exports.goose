namespace vm;

import.host_api;

export fn goose_vm_seed_storage(key: const u8[:], value: const u8[:]) {
    host_storage_put_raw(key, value);
}

export fn goose_vm_remove_storage(key: const u8[:]) {
    host_storage_remove_raw(key);
}

export fn goose_vm_set_route_state(path: const u8[:]) {
    host_set_route_raw(path);
}

export fn goose_vm_set_route_info(info: const u8[:]) {
    host_set_route_info_raw(info);
}

export fn goose_vm_host_outbox() -> const u8[:] {
    return host_outbox_bytes();
}

export fn goose_vm_clear_host_outbox() {
    host_clear_outbox();
}
