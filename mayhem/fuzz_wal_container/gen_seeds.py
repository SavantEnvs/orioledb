#!/usr/bin/env python3
"""Regenerates testsuite/: hand-built OrioleDB WAL containers, one per record shape and WAL version.

Wire layout follows include/recovery/wal.h (WALRec* structs) and src/recovery/wal_reader.c.
"""
import os
import struct

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "testsuite")

XID, COMMIT, ROLLBACK, RELATION, INSERT, UPDATE, DELETE = 1, 2, 3, 4, 5, 6, 7
META_LOCK, META_UNLOCK, SAVEPOINT, RB_TO_SP, JOINT_COMMIT = 8, 9, 10, 11, 12
TRUNCATE, BRIDGE_ERASE, REINSERT, REPLAY_FEEDBACK, SWITCH_XID = 13, 14, 15, 16, 17
RELREPLIDENT, DB_COPY, DB_CREATE_COPY, DB_TEMPLATE_CKPT = 18, 19, 20, 21
CIC_WRITERS, CIC_DRAIN, CIC_VALID, UPDATE_PARTIAL = 22, 23, 24, 25

u8 = lambda v: struct.pack("<B", v)
u16 = lambda v: struct.pack("<H", v)
u32 = lambda v: struct.pack("<I", v)
u64 = lambda v: struct.pack("<Q", v)


def header(ver, flags=0, extra=b""):
    if ver == 0:
        return b""
    h = u16(ver)
    if ver >= 17:
        h += u8(flags) + extra
    return h


def rec_xid(ver, oxid=0x1234, lxid=7, hxid=900):
    return u8(XID) + u64(oxid) + u32(lxid) + (u32(hxid) if ver >= 17 else b"")


def rec_finish(t, xmin=10, csn=11):
    return u8(t) + u64(xmin) + u64(csn)


def rec_relation(ver, tree=1, dat=5, rel=16384, node=16390, spc=1663):
    r = u8(RELATION) + u8(tree) + u32(dat) + u32(rel) + u32(node)
    if ver >= 17:
        r += u64(3) + u64(4) + u32(0) + u32(2) + u32(1)
    if ver >= 18:
        r += u32(spc)
    return r


def tup(data):
    return data


def rec_modify(ver, t, data, flags=0):
    length = u32(len(data)) if ver >= 20 else u16(len(data))
    return u8(t) + u8(flags) + length + data


def rec_modify2(ver, t, d1, d2):
    if ver >= 20:
        lens = u32(len(d1)) + u32(len(d2))
    else:
        lens = u16(len(d1)) + u16(len(d2))
    return u8(t) + u8(0) + u8(1) + lens + d1 + d2


def rec_joint(ver):
    return u8(JOINT_COMMIT) + u32(55) + u64(10) + u64(11) + (u8(1) if ver >= 19 else b"")


def rec_rb_sp(ver):
    return u8(RB_TO_SP) + u32(2) + (u64(10) + u64(11) if ver >= 17 else b"")


ROW = b"\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f"
BIG = bytes(range(256)) * 4

seeds = {}


def add(name, blob):
    seeds[name] = blob


for ver in (21, 20, 19, 18, 17, 16, 0):
    s = header(ver)
    s += rec_xid(ver) + rec_relation(ver)
    s += rec_modify(ver, INSERT, ROW) + rec_modify(ver, DELETE, ROW[:8]) + rec_finish(COMMIT)
    add(f"v{ver:02d}_insert_commit", s)

v = 21
add("v21_update_replident_full",
    header(v) + rec_xid(v) + rec_relation(v) + u8(RELREPLIDENT) + u8(ord("f")) + u32(0)
    + rec_modify2(v, UPDATE, ROW, ROW[::-1]) + rec_finish(COMMIT))
add("v21_update_default",
    header(v) + rec_xid(v) + rec_relation(v) + rec_modify(v, UPDATE, ROW) + rec_finish(ROLLBACK))
add("v21_reinsert", header(v) + rec_xid(v) + rec_relation(v) + rec_modify2(v, REINSERT, ROW, ROW))
add("v21_update_partial", header(v) + rec_xid(v) + rec_relation(v) + rec_modify(v, UPDATE_PARTIAL, ROW, 1))
add("v21_big_old_tuple",
    header(v) + rec_xid(v) + rec_relation(v) + u8(RELREPLIDENT) + u8(ord("f")) + u32(0)
    + rec_modify2(v, UPDATE, BIG, ROW) + rec_finish(COMMIT))
add("v21_xact_info", header(v, 1, u64(700000000000000) + u32(1234)) + rec_xid(v) + rec_finish(COMMIT))
add("v21_origin_info", header(v, 2, u16(1) + u64(0x1000000)) + rec_xid(v) + rec_finish(COMMIT))
add("v21_xact_origin_info",
    header(v, 3, u64(700000000000000) + u32(1234) + u16(1) + u64(0x1000000)) + rec_xid(v) + rec_finish(COMMIT))
add("v21_savepoints",
    header(v) + rec_xid(v) + u8(SAVEPOINT) + u32(1) + u32(8) + u32(7) + rec_rb_sp(v)
    + u8(SWITCH_XID) + u32(7) + u32(8) + rec_joint(v))
add("v21_markers",
    header(v) + u8(META_LOCK) + u8(REPLAY_FEEDBACK)
    + u8(META_UNLOCK) + u32(5) + u32(16384) + u32(16390) + u32(16395))
add("v21_truncate_bridge",
    header(v) + u8(TRUNCATE) + u32(5) + u32(16384) + u32(16390) + u8(BRIDGE_ERASE) + u16(0) + u16(1) + u16(3))
add("v21_database",
    header(v) + u8(DB_COPY) + u32(16400) + u32(1663) + u32(1664)
    + u8(DB_CREATE_COPY) + u32(1) + u32(16401) + u8(DB_TEMPLATE_CKPT) + u32(1) + u32(16401))
add("v21_cic",
    header(v) + u8(CIC_WRITERS) + u32(5) * 1 + u32(16384) + u32(16390) + u32(16384) + u32(16385) + u32(1)
    + u8(CIC_VALID) + u32(5) + u32(16384) + u32(16390) + u32(16384) + u32(16385) + u32(2))
add("v21_sys_tree_relation", header(v) + rec_relation(v, dat=1, rel=0, node=3))
add("v19_joint_commit", header(19) + rec_xid(19) + rec_joint(19))
add("v17_savepoint_rollback", header(17) + rec_xid(17) + rec_rb_sp(17))
add("v00_xid_commit", header(0) + rec_xid(0) + rec_finish(COMMIT))

os.makedirs(OUT, exist_ok=True)
for f in os.listdir(OUT):
    os.remove(os.path.join(OUT, f))
for name, blob in seeds.items():
    with open(os.path.join(OUT, name), "wb") as fh:
        fh.write(blob)
print(len(seeds), "seeds")
