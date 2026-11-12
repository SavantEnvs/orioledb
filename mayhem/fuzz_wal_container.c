/*
 * libFuzzer harness for OrioleDB's WAL container parser (src/recovery/wal_reader.c).
 *
 * The input is one WAL container exactly as the replay path (recovery.c,
 * replay_check_version/replay_on_container/replay_on_record) receives it: a
 * version header, container flags, then a stream of tagged records. Every
 * record is handed to a consumer that, like replay, copies the tuples of
 * modify records with build_fixed_tuples() and then reads all of their bytes.
 */
#include "postgres.h"

#include "orioledb.h"

#include "btree/page_contents.h"
#include "recovery/wal.h"
#include "recovery/wal_reader.h"
#include "utils/memutils.h"

/* normally defined by the postmaster's main(), which is not linked in */
const char *progname = "fuzz_wal_container";

typedef struct
{
	uint64		digest;
	uint32		records;
} FuzzCtx;

static void
mix(FuzzCtx *ctx, const unsigned char *p, size_t n)
{
	size_t		i;

	for (i = 0; i < n; i++)
		ctx->digest = ctx->digest * 1099511628211ULL + p[i];
}

static WalParseResult
fuzz_check_version(const WalReaderState *r)
{
	if (r->container.version > ORIOLEDB_WAL_VERSION)
		return WALPARSE_BAD_VERSION;
	return WALPARSE_OK;
}

static WalParseResult
fuzz_on_container(WalReaderState *r)
{
	FuzzCtx    *ctx = (FuzzCtx *) r->ctx;

	mix(ctx, (const unsigned char *) &r->container.flags, sizeof(r->container.flags));
	return WALPARSE_OK;
}

static WalParseResult
fuzz_on_record(WalReaderState *r, WalRecord *rec)
{
	FuzzCtx    *ctx = (FuzzCtx *) r->ctx;
	const char *name = wal_type_name(rec->type);

	ctx->records++;
	mix(ctx, (const unsigned char *) name, strlen(name));
	mix(ctx, (const unsigned char *) &rec->oxid, sizeof(rec->oxid));

	switch (rec->type)
	{
		case WAL_REC_INSERT:
		case WAL_REC_UPDATE:
		case WAL_REC_DELETE:
		case WAL_REC_REINSERT:
		case WAL_REC_UPDATE_PARTIAL:
			{
				OFixedTuple tuple1;
				OFixedTuple tuple2;

				build_fixed_tuples(rec, &tuple1, &tuple2);
				mix(ctx, (const unsigned char *) tuple1.tuple.data,
					MAXALIGN(rec->u.modify.len1));
				if (rec->u.modify.read_two_tuples)
					mix(ctx, (const unsigned char *) tuple2.tuple.data,
						MAXALIGN(rec->u.modify.len2));
				break;
			}
		default:
			break;
	}
	return WALPARSE_OK;
}

int
LLVMFuzzerInitialize(int *argc, char ***argv)
{
	MemoryContextInit();
	return 0;
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	FuzzCtx		ctx = {14695981039346656037ULL, 0};
	WalReaderState r;
	Pointer		buf;

	/* the container header is read unconditionally; real containers are never empty */
	if (size == 0)
		return 0;

	/* exact-size heap copy so ASan sees any read past the container end */
	buf = malloc(size);
	memcpy(buf, data, size);

	memset(&r, 0, sizeof(r));
	r.start = buf;
	r.end = buf + size;
	r.ptr = buf;
	r.ctx = &ctx;
	r.check_version = fuzz_check_version;
	r.on_container = fuzz_on_container;
	r.on_record = fuzz_on_record;

	(void) wal_parse_container(&r, false);

	free(buf);
	return 0;
}
