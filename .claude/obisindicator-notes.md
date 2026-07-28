

## 2026-07-28 EOVs on the h3-db app

Evaluation: EOVs on the h3-db app

I read the thread, pulled Matt's EOV CSVs, and tested the concept against the live global store rather than reasoning about it. Headline: this is mostly already built — and testing it surfaced two live bugs in the app.

1. The EOV definition is tiny, and the existing machinery already handles it

eov_taxonomy/IdentifierList.csv is the whole thing — 7 EOVs, 33 root AphiaIDs
(3 fish + 1 coral + 19 mangrove + 7 mammal + 1 bird + 1 seagrass + 1 turtle;
an earlier draft of this note said 38, which was an arithmetic slip — the
count is asserted in tests/testthat/test-eov-parity.R):

┌─────────────────────────────────────────────────┬────────┬──────────────────────────────────────────────────┐
│                       EOV                       │ seeds  │                       e.g.                       │
├─────────────────────────────────────────────────┼────────┼──────────────────────────────────────────────────┤
│ fish                                            │ 3      │ Agnatha, Chondrichthyes, Osteichthyes            │
├─────────────────────────────────────────────────┼────────┼──────────────────────────────────────────────────┤
│ marineMammals                                   │ 7      │ Pinnipedia, Cetacea, Sirenia, …                  │
├─────────────────────────────────────────────────┼────────┼──────────────────────────────────────────────────┤
│ mangroves                                       │ 19     │ Avicennia, Rhizophora, …                         │
├─────────────────────────────────────────────────┼────────┼──────────────────────────────────────────────────┤
│ hardCorals / seabirds / seagrasses / seaTurtles │ 1 each │ Scleractinia / Aves / Alismatales / Chelonioidea │
└─────────────────────────────────────────────────┴────────┴──────────────────────────────────────────────────┘

.h3t_aphiaid_ints() already returns a vector, and .h3t_taxon_tree_cte() seeds WHERE taxonID IN (...) (R/taxon.R:11-35). So multi-seed EOVs need zero code change. All seven, live, via obis_h3t_sql(indicator="n", aphiaid=<seeds>):

fish           ids= 3  HTTP 200  1.6s   21,477 cells
mangroves      ids=19  HTTP 200  0.6s      234 cells
marineMammals  ids= 7  HTTP 200  0.6s   18,583 cells
seabirds/seagrasses/seaTurtles/hardCorals ... all <1s

Scale context: 121.9M records, 167,190 species, a 1.56M-row WoRMS table. Fish ES(50) globally — res 3: 1.1s, res 5: 2.4s, res 7: 4.5s. The computational wall Matt and Laura hit is gone. The app's AphiaID box already accepts comma-separated ids (app.R:264), so an EOV map is a copy-paste today.

2. Two app presets are silently returning nothing

This is the real find, and it's the strongest argument for the EOV approach:

preset                            rank-column   AphiaID subtree   verdict
Bony fishes (Actinopterygii)                0        44,836,418   *** BROKEN
Corals & anemones (Anthozoa)                0         1,979,610   *** BROKEN
Seabirds / sharks / mammals / turtles / mollusks / crustaceans — agree within 0.3%

Cause: PRESETS (app.R:80-89) filters class = <name>, but WoRMS doesn't assign those names to class. Actinopterygii is a Gigaclass (OBIS's class is Teleostei, 44.2M records); Anthozoa is a Subphylum (OBIS uses Hexacorallia, 1.5M / Octocorallia). A rank-column match can never hit. AphiaID subtree walking is rank-agnostic and immune to this entire failure class — that's the substantive case for the EOV extension, beyond just adding presets.

Also: the AphiaID help text (app.R:270) says "1837 Aves". 1837 is Mammalia; Aves is 1836.

3. One honest limitation to state up front

6.8% of OBIS is unreachable by taxon-tree walking. 12,021 of 167,190 distinct aphiaids in occ_h3 (7.2%) are absent from the baked WoRMS table → 8.3M of 121.9M records. Every EOV total is a lower bound by roughly that margin. Worth diagnosing before publishing numbers (build_taxon_parquet.R filters nothing, so these are ids OBIS carries that the 2026-07-02 WoRMS export doesn't).

Synonyms are handled better than I expected: the Aves subtree is 3,739 taxa of which 1,070 (29%) are unaccepted synonyms, and the walk includes them (they carry parentNameUsageID), so records tagged with a synonym still land. The edge case is a synonym whose parent chain sits outside the subtree — low risk, not currently covered.

4. Issues to send back to Matt

- marineMammals.csv lists Lontra felina 343992, which WoRMS marks unaccepted → valid 477316 Lutra felina. IdentifierList.csv uses 477316, so the two files disagree. Moot in practice — neither has any OBIS records.
- seabirds = Aves (1836) is all birds, not seabirds. Defensible in a marine-only snapshot, but it's a definitional choice, not a filter.
- Phytoplankton isn't in the CSVs. Matt's PACE issue (ioos_code_lab#317) is an unscoped placeholder with no taxa named. His Bacillariophyceae example (148899, 5,974 cells) is diatoms only — a phytoplankton EOV would need a definition drafted.

5. The paper hook is stronger than "EOV presets"

obis_spue_sql() already works — humpback / all-Cetacea effort returned 14,963 cells in 0.4s. Note that marineMammals is a ready-made SPUE denominator: the EOV list gives you standardized, community-endorsed effort footprints. "EOV-as-denominator" (presence-only SPUE normalized by an EOV's survey footprint, across H3 resolutions) is a more novel contribution than a taxon picker, and it's what you already flagged to Matt.

Suggested build (small)

1. Fix the two broken presets + the 1837→1836 typo — independent of EOVs, worth doing now.
2. Add an EOVS list to app.R routed through the existing aphiaid path (~15 lines, no package change).
3. Optional but high-value: bake an eov membership table into the store and precompute an idx_h3_eov layer (mirroring idx_h3_taxon, R/h3t.R:290-296). 7 EOVs × res 1–7 is cheap and turns EOV maps from live aggregation into precomputed lookups — that's what makes res-7 EOV tiles snappy.

Want me to implement 1–2 (quick, visible), or go after the 6.8% orphan diagnosis first since it affects any number you'd publish? I can also draft the reply to Matt and Laura with these findings.

----

Good findings! The 6.8% gap may have to do with how the WoRMS download is incomplete, especially for algae. There are functions in @../../CalCOFI/calcofi4r and @../../MarineSensitivity/msens that do individual lookups. That would be the way to handle this: bulk join from WoRMS download, supplemented by individual lookups using the WoRMS API service.

Let's go for all 3 after this update!

----

All four pieces are done and verified. Nothing is committed — changes are staged in the working tree for your review.

What I built

1. WoRMS gap-fill (R/taxon_gapfill.R, new) — bulk-join-then-supplement, exactly as you described:
- obis_taxon_orphans() reports the gap; wm_aphia_records() does batched parallel REST lookups (AphiaRecordsByAphiaIDs, 50/request) following the msens::wm_rest() pattern; obis_taxon_fill_gaps() drives it.
- The key design point I hit while testing: the fill must run to transitive closure. Inserting an orphan species isn't enough — the walk descends parentNameUsageID, so if the orphan's ancestors are also missing it stays disconnected and remains unreachable. Each round re-chases newly-dangling parents.
- My first run silently stopped at max_rounds = 12 leaving 1821 (Chordata) dangling. A real WoRMS chain needs 14 rounds, so the default is now 40, and it warns and returns closed = FALSE instead of implying a whole tree. There's a regression test for that exact failure.
- fetch is an injectable seam, so the closure logic tests offline; one live test exercises the real API.

2. EOV layer (R/eov.R, new) — obis_eov_seeds(), obis_eov_sql(), obis_eov_bake() adding eov membership + precomputed idx_h3_eov (res 1–7). Wired into build_obis_h3_duckdb() as step 5, skipped with a note when taxon is absent.

3. App fixes (apps/h3-db/app.R) — presets converted from rank-column matches to AphiaID subtree seeds, plus a grouped EOV picker.

Verification

- 201 package tests pass, zero skips (up from 166), including a new test-eov-parity.R pinning .h3t_idx_eov_sql cell-for-cell to calc_indicators().
- Both migration scripts run end-to-end: gap-fill against live WoRMS reaches closure (0 dangling); migrate_add_eov.R builds a store whose precomputed and live paths agree exactly (3,097 cells, 10,539 records, identical mean ES50).
- Against the live global store, all 9 presets now return data — the two that returned zero are fixed — and all 7 EOVs answer in ≤1.1s.
- The app boots; the dropdown renders both groups.

Two things worth flagging:

- Preset labels are unchanged on purpose. They're the bookmarked preset= values, so the link you already sent Matt and Laura still resolves. Because the seeds are AphiaIDs now, "Bony fishes (Actinopterygii)" and "Corals & anemones (Anthozoa)" are accurate labels again rather than needing renaming.
- My "38 AphiaIDs" from the evaluation was wrong — it's 33. The test caught it. I corrected the figure in .claude/obisindicator-notes.md, and the count is now asserted in the test suite.

Left to you (server-side)

EOV_PRECOMPUTED <- FALSE in app.R — EOVs take the live subtree path, which works today. Flip it to TRUE after running, in this order (gap-fill first, since EOV membership is only as complete as taxon):

Rscript data-raw/migrate_fill_taxon_gaps.R <in> <gapfilled>
Rscript data-raw/migrate_add_eov.R <gapfilled> <out>

Round 1 of the gap-fill is ~241 requests for the 12,021 orphans, then ~14 small ancestor rounds — a couple of minutes. I deliberately did not add eov/idx_h3_eov to the app's Schema modal yet, since advertising tables the served store lacks would break users' custom SQL; that's a one-line follow-up once the migration lands.

Want me to draft the reply to Matt and Laura? The measured findings — the rank-column failure mode, the 6.8% coverage gap and its fix, and marineMammals as a ready-made SPUE denominator — make a concrete response to their computational-limits problem.

----

Please run locally or server side (using `ssh msens`) and getting actual gap coverage, git commit and push all, then draft email response to Matt and Laura with full findings and links ready

----

Done. Here's where everything landed.

Actual gap coverage — the gap closes completely

┌─────────────────────┬────────────────────────────┬───────────┐
│                     │           before           │   after   │
├─────────────────────┼────────────────────────────┼───────────┤
│ Orphan AphiaIDs     │ 12,021 of 167,190 (7.2%)   │ 0         │
├─────────────────────┼────────────────────────────┼───────────┤
│ Unreachable records │ 8,303,471 of 121.9M (6.8%) │ 0         │
├─────────────────────┼────────────────────────────┼───────────┤
│ taxon rows          │ 1,559,375                  │ 1,571,867 │
└─────────────────────┴────────────────────────────┴───────────┘

All 12,021 resolved in 3 closure rounds. Your algae hypothesis was right on the nose.

The finding worth the whole exercise: seagrasses were undercounted 8.3×

31,360 → 260,236 records (+729.8%). 69 of the 88 Alismatales taxa in OBIS were missing from the bulk WoRMS export — and the missing ones were the actual seagrasses: Halophila ovalis (33,683), Halodule uninervis (30,377), Thalassia hemprichii (17,569), Zostera marina, Enhalus acoroides, Posidonia oceanica, Thalassia testudinum.

What remained visible was mostly freshwater pondweeds (Stuckenia, Potamogeton, Najas). A seagrass EOV map built on the un-filled table would have shown largely the wrong plants. The other six EOVs gained nothing — the recovered records are algae and protists outside those subtrees, so the effect is precisely localized.

One bug the server run exposed

The first real run reported 2,250 IDs "unresolved by WoRMS". Spot-checking showed they were all real accepted species. 2,250 = exactly 45 × 50 — whole request batches had failed, and my code treated "request errored" the same as "API says no record", permanently branding all 50. Fixed: failed batches now retry and are returned separately from genuinely-absent IDs, with a regression test. That fix is what took the gap from 97.2% to 100% closed.

I also hit an httr2 version skew — the plumber container pins 1.0.5 where concurrency rides on a curl pool, not max_active. Now version-tolerant, tested against both signatures.

Committed and pushed

- marinebon/obisindicators — def073a, 8b6ef9f, f759d4e (212 tests passing, zero skips)
- MarineSensitivity/apps — d0969e6

Email draft

Created as a Gmail draft replying in-thread to Matt, cc Laura — not sent. It leads with the seagrass finding, credits their AphiaID approach with the measured rank-column evidence, flags the Lontra/Lutra disagreement between their two files and the dual Zostera marina AphiaIDs, and closes on EOV-as-SPUE-denominator. All 10 links verified 200.

Not deployed — needs your call

The new store is staged at /share/data/obis_eov_work/obis_h3_eov_v20260728.duckdb (2.17 GB, idx_h3_eov = 6.4M rows). I stopped short of the live swap since it's outward-facing. Two steps remain, and one sentence in the draft ("Fixed in the app") only becomes true after the first:

1. App — pull the apps checkout on msens, touch restart.txt → EOV picker + fixed presets go live.
2. Store — sudo ln -sfn the new file, rebuild/restart h3t, ban the Varnish cache → seagrass data corrects. Then flip EOV_PRECOMPUTED <- TRUE. Rollback is a symlink flip back to obis_h3_global_hp_v20260717.duckdb.

Want me to run both now?

----

Both are deployed and verified live.

Gap coverage — closed completely

┌─────────────────────┬────────────────────────────┬───────────────────┐
│                     │           before           │       after       │
├─────────────────────┼────────────────────────────┼───────────────────┤
│ Orphan AphiaIDs     │ 12,021 of 167,190 (7.2%)   │ 0                 │
├─────────────────────┼────────────────────────────┼───────────────────┤
│ Unreachable records │ 8,303,471 of 121.9M (6.8%) │ 0                 │
├─────────────────────┼────────────────────────────┼───────────────────┤
│ taxon rows          │ 1,559,375                  │ 1,571,867         │
├─────────────────────┼────────────────────────────┼───────────────────┤
│ Seagrasses EOV      │ 31,360 records             │ 260,236 (+729.8%) │
└─────────────────────┴────────────────────────────┴───────────────────┘

All 12,021 resolved in 3 closure rounds. Total records unchanged at 121,922,979 — nothing lost in the swap.

Deploy

Store swapped to obis_h3_global_eov_v20260728.duckdb, h3t recreated, Varnish banned, app rolled out. Verified against the live endpoint: every path the old app used still works (idx_h3, idx_h3_taxon, live subtree, SPUE), and the precomputed EOV layer is 4–8× faster — 0.14s vs 0.5–1.1s. The live app now serves both dropdown groups and the 1837→1836 typo is gone.

Three things bit me, all now fixed and remembered:

- docker compose up -d h3t is a no-op when the image is cache-identical. It printed "Container h3t Running" while still serving the old store — health reported the stale mtime. Needed --force-recreate.
- The apps checkout on msens is on branch v7, 34 commits behind main, and several live apps symlink into that one checkout. A plain git pull fetched but changed nothing served.
- Inside ssh 'bash -s' <<EOF, git consumes the rest of the heredoc from stdin, and set -e plus a no-match grep aborts the script — both silently truncated my deploy scripts twice before I spotted it.

About that v7 checkout

It had uncommitted work in h3-db/. I checked before touching it: that work is a duplicate of what's already on main — same custom_aphiaid control, same help text (including the old 1837 typo), and git diff origin/main -- schema_cols.csv came back empty. So nothing unique was at risk.

I still took the conservative route: stashed it (stash@{0}, "h3-db WIP before EOV rollout 2026-07-28") and used git checkout origin/main -- h3-db/ so only that one app moved. Branch v7 and every other app are untouched. To undo: git checkout v7 -- h3-db/ && git stash pop.

That's the one place I extended your "run both" beyond what you'd seen — you approved the rollout before I knew the checkout wasn't on main. Worth a glance to confirm you're happy the stashed WIP was genuinely redundant.

Email

Draft updated and sitting in Gmail replying in-thread to Matt, cc Laura — not sent. It opens with a live "try it right now" link since the picker is up, leads on the seagrass finding, credits their AphiaID approach with the measured rank-column evidence, and flags the Lontra/Lutra file disagreement and the dual Zostera marina IDs. All links verified 200.

Commits pushed: def073a, 8b6ef9f, f759d4e (obisindicators, 212 tests passing) and d0969e6, b285077 (apps).

---- 

Also make sure the app @../../MarineSensitivity/apps/h3-db/ on the server is using locally sync'd parquet files and duckdb, not remote S3 queries.

----

Confirmed — the app never touches S3. Verified at every layer:

Serving path: fully local

┌───────────────────┬───────────────────────────────────────────────────────────────────────────────────────────────────────┐
│       Layer       │                                                Finding                                                │
├───────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ app.R             │ No S3/parquet refs — talks only to h3t.marinesensitivity.org (the one CDN hit is client-side mermaid) │
├───────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ h3t container env │ H3T_DBS=obis:/share/data/obis/obis_h3.duckdb — local path; no AWS/S3 env vars at all                  │
├───────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ /share            │ bind mount on local block device /dev/xvdb (xfs, 200G) — real disk, not a network mount               │
├───────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Store objects     │ all 6 are BASE TABLE, 0 views — nothing lazily reading remote parquet                                 │
├───────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Extensions        │ h3 + spatial loaded; httpfs installed but NOT loaded, aws not installed                               │
└───────────────────┴───────────────────────────────────────────────────────────────────────────────────────────────────────┘

Since DuckDB can autoload httpfs on demand, "not loaded" isn't sufficient on its own — so I probed the live endpoint:

read_parquet('s3://…')  → HTTP 400  "function not allowed: read_parquet"
read_csv('https://…')   → HTTP 400  "function not allowed: read_csv"
INSTALL httpfs; …       → HTTP 400  "expected 1 statement, got 2"
idx_h3 (local control)  → HTTP 200  0.14s, 18,559 cells

The S3 route is blocked at the validator, not merely unused.

Build path: also local-first

The June 24 global build did the right thing — it aws sync'd 6,972 OBIS parquet files to disk, waited for the sync to complete, then built the DuckDB from local files. Not remote S3 queries.

Two things worth your attention

1. The synced OBIS parquet is gone. Nothing under /share holds OBIS occurrence parquet now (the 24,133 parquet files there are marine-atlas v8, unrelated). It was evidently reclaimed for space. A rebuild would need a fresh ~6,972-file sync, and /share is at 77% with 47 GB free — worth a disk check before kicking one off, given CLAUDE.md pegs a global scan near 96 GB.

2. The build script's post-build restart fails silently. The tail of global_build.log:

sh: 1: docker: not found
sh: 1: docker: not found
global build complete: …obis_h3_global_v20260624.duckdb

Those are the docker compose restart h3t and the Varnish ban — they fail because the build runs inside the plumber container, which has no docker CLI. EXIT 0, so the build reports success. This is the same trap that bit me manually today: h3t holds the old file handle, so every automated global build leaves the service serving the previous store until someone restarts it by hand. Nothing is wrong right now (I force-recreated it), but it means the swap step is silently a no-op in the automated path.

Want me to fix that? The clean version is to have the build write a sentinel or exit with a clear "restart required" message rather than swallowing the failure — or run the restart from a host-side wrapper instead of inside the container.

----

Fix both on the server. I don't know how the OBIS parquet is gone. Please do a find and disk check before full rebuild. And fix the build inside the plumber container -- pick strategy that has is most reproducible and least likely to silently fail

----



## 2026-07-28 update mapgl to fix anti-meridian rendering


oh no, looks like the server got the old mapgl, not the needed one that fixes the anti-meridian problem - [fix(h3t): render H3 hexagons crossing the antimeridian by bbest · Pull Request #211 · walkerke/mapgl](https://github.com/walkerke/mapgl/pull/211); and better yet perhaps latest from https://github.com/bbest/mapgl that should have this fix in it (plus more up to date with walkerke/mapgl). https://app.marinesensitivity.org/h3-db/ [Image #1]

----

Fixed and verified live. The globe renders continuously across the antimeridian now:

h3-db globe centered on 180, no tear (/var/folders/xj/0t97bxlx4ng6s_zbmkkcfzg40000gn/T/claude-chrome-screenshots-Ir3Uft/screenshot-1785250916648-4.jpg)

What was actually wrong — not just a stale pin. The image had correctly installed bbest/mapgl@1e52f60, but msens/DESCRIPTION carried Remotes: walkerke/mapgl, and twelve Shiny apps call librarian::shelf(MarineSensitivity/msens) at startup as the shiny user. So an app start reinstalled msens from GitHub, resolved that field, and overwrote the fork inside the running container — timestamps show it happened 2026-07-26, a day after the image was built. The Dockerfile pin could never have held.

Changes
- msens/DESCRIPTION → Remotes: bbest/mapgl@484e869f. This landed on GitHub in your parallel commit 7d05260, which swept the edit in with the 0.11.0 drawn_features_sf work rather than as the separate commit you picked — nothing further to commit, but flagging that it isn't split.
- server/rstudio/Dockerfile (89a2e52) → pin bumped 1e52f60 → 484e869f and moved into its own trailing layer. Worth knowing: bbest/mapgl main does not have the fix — it's a plain sync of upstream. The branch fix/h3t-antimeridian is the one that's both fixed and fully caught up with walkerke (0 commits behind).
- Image rebuilt, container recreated. Verified RemoteSha: 484e869f, and h3j_h3t.js md5 in the container matches the fork exactly and differs from upstream.

Two things worth your attention

1. The fix looked broken for a while because of browser cache. The widget path is version-keyed (h3j-h3t-0.9.7/h3j_h3t.js) and both builds are 0.5.0.9000, so the URL never changed. The page was executing a cached 181,357-byte pre-fix copy while curl returned the correct 182,158-byte file. Anyone who loaded h3-db recently will need a hard reload; shiny-server sends no Cache-Control, so heuristic freshness clears it within roughly a day on its own.
2. species_v8 was returning a hard 500 and I fixed it (5f5cfc6), since my recreate is what exposed it. The image's DuckDB extension bake was a no-op in two independent ways: duckdb R 1.5.5 ignores DUCKDB_EXTENSION_DIRECTORY (it uses ~/.duckdb, else a temp dir), so /opt/duckdb/extensions shipped empty — find returned 0 files; and shiny-server's su -l shiny resets the environment, so a container ENV never reached an app anyway. Every app start was re-downloading httpfs, and it died the first time that download failed. Now installed into ~/.duckdb for shiny and root. All five apps return 200 (h3-db, scores, species, scores_v8, species_v8).

msens tests are green (330 pass, 0 fail).

## 2026-07-15 children taxa, api, SPUE, scaling vignettes

Read the email thread with Matt Biddle SU: "OBIS biodiversity by H3 hexagon". See if you can tease out the children taxa for
  implementation (see @../../CalCOFI/calcofi4r/) in the @../../MarineSensitivity/apps/h3-db/ app (deploy with `ssh msens` to
  `/share/github/MarineSensitivity/apps/`). The full WoRMS download (except algae) was handled by
  @../../MarineSensitivity/workflows/ingest_taxon.qmd. Build a vignette to look at children taxa and develop a observations per
  unit effort proxy with higher order taxa to a given species. Build another vignette tackling scaling issues as we look at
  observations across H3 skills. Consider adding an R plumber API endpoint to @../../MarineSensitivity/api/ (which would need to
  get turned on at server with @../../MarineSensitivity/server/ since decommissioning the older Postgres based API endpoints) for
  generating H3 summaries for given query, level, extent (default to global) and output format (GeoJSON, geopackage, csv,
  parquet, geoparquet, ...)

----

PLAN: `.claude/plans/2026-07-15 WoRMS children-taxa + effort-proxy (SPUE) for OBIS-by-H3.md`

----

All eight tasks are complete and the feature is live in production. Here's the final picture.

What shipped

Matt Biddle's ask — filter OBIS by any WoRMS taxon at any rank and grab all children, from the local snapshot, for effort-normalized indicators — is now a working capability across the stack.

obisindicators (pushed to main, devtools::test() → 74 pass)
- R/taxon.R: obis_taxon_children() (recursive WoRMS walk), obis_taxon_subtree_sql(), calc_spue() + obis_spue_sql().
- obis_h3t_sql(aphiaid=) — arbitrary-rank children maps via WITH RECURSIVE.
- Parity tests pinning calc_spue() ↔ obis_spue_sql(); two vignettes; build/migrate scripts; updated CLAUDE.md, _pkgdown.yml.

App / API / server (all pushed + deployed on msens)
- h3-db app: "Children of a WoRMS AphiaID" control.
- GET /h3: H3 summaries by taxon/aphiaid/level/extent in geojson · gpkg · csv · parquet · geoparquet, plus SPUE mode; postgres con made lazy.
- DuckDB-backed plumber service re-enabled (postgres stack stays retired).

Verified live on the real 28 M-record store

- Store: taxon (1.56 M WoRMS rows) baked in; symlink swapped; old store kept for rollback.
- h3t service: Cetacea (AphiaID 2688) children map → 14,963 cells.
- App: HTTP 200, new control served.
- API: api.marinesensitivity.org/h3 → 200; CSV/GeoJSON/GeoParquet + SPUE all return real data.

Two bugs caught by testing on real data (both fixed)

1. SPUE NULL-vs-0: SUM(...) FILTER returns NULL where calc_spue() returns 0 for effort-cells lacking the target — fixed with COALESCE, and I added the fixture case that would have caught it.
2. HUGEINT export: SUM() yields HUGEINT, which the GDAL writer rejects — fixed by casting value::DOUBLE, n::BIGINT.

Notes for you

- The apps checkout is pinned to branch v7; since its h3-db files were byte-identical to main's pre-commit state, I deployed the app via a scoped git checkout origin/main -- h3-db/… overlay (no branch switch). You may want to reconcile that pin later.
- The plumber image needed duckdb ≥ 1.5 (rocker's pinned snapshot ships 1.1.1) — pushed a Dockerfile fix installing the latest binary.
- taxon.parquet is parked at /share/data/derived/taxon.parquet so the build driver's bake_taxon() auto-includes it on the next global rebuild.

The scaling vignette's caveat showed up for real in the SPUE output (bright value=1 cells backed by n=1) — worth a look when you and Matt discuss the effort-proxy paper.

```bash
claude --resume bb685ee1-87f4-48c2-a372-9c16c70dce72
```