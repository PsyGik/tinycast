# Search Files

Search Files is an on-demand palette screen for opening files and folders from the folders the user
configures. It searches filenames through Spotlight, adds no private index or launch work, and is
reached from the built-in Search Files launcher command — or its own global shortcut — after the
feature is enabled in Settings.

## Invariants

- **Every Spotlight query is capped before execution, and the rows after filtering.** The row cap
  is the **Maximum results** setting (100 to 1,000, default 200); the candidate cap is twice that, never
  under 1,000, so the default stays 1,000 and 200. `MDQuerySetMaxCount` is the reason the
  feature uses `MDQuery`; `NSMetadataQuery` has no source-result cap and can break the 100 MB budget on
  a broad filename.
- **Everything under `Model/` stays Foundation-only and pure**, `FileSearchIgnoreList`'s `import Darwin`
  and the `UniformTypeIdentifiers` of `FileSearchFilter` and `FileSearchPreviewKind` included — value
  types with no environment of their own. `file-search-test` compiles the shipped files together with
  the existing pure fuzzy scorer.
- **Search is filename-only, and every list comes from Spotlight.** Tinycast creates no content index,
  history, query cache, watcher or search data — the blank screen's Recently Used rows are one more
  Spotlight query over the configured scopes, read from the system's own `kMDItemLastUsedDate` and
  `kMDItemFSContentChangeDate`, never from anything Tinycast recorded. The type filter narrows *which*
  files Spotlight is asked for; it never adds a second pass over the ones it returned.
- **The filter belongs to the query, not to the rows.** `FileSearchSession` keys its de-dup and its
  supersession check on the query and the filter together, so narrowing re-runs the same words rather
  than thinning a result set that was already capped.
- **Hidden paths and application-bundle contents are structural, not patterns.** They are what keeps
  the feature permission-free, so no user setting can re-admit them. Everything else that is dropped
  comes from the ignore list.
- **`~/Library` is never a scope Tinycast picks by itself.** A configured home root expands into its
  visible children plus the two cloud-storage roots instead. A user who adds a folder under `~/Library`
  by hand gets what they asked for.
- **The shipped ignore rules are compiled in and never persisted.** `fileSearchIgnorePatterns` stores
  only what the user added, so changing `FileSearchIgnoreList.defaults` reaches installs that already
  ran. The consequence is that the shipped six cannot be switched off.
- **File Search is off by default, and off means no entry point or Spotlight work.** A nonempty query
  on that screen is the first operation that searches, and the global shortcut no-ops while the
  feature switch is off.
- **Searching asks for no file permission; browsing asks only on an explicit step.** Hidden metadata
  items and application bundles are filtered, and Spotlight or TCC omissions produce a thinner result
  set rather than a prompt for Full Disk Access. Browse Files reads a folder only when the user walks
  into it — →, ↵, a click or a typed path — and a folder row's preview is its icon, never its contents,
  so macOS's one-time prompt for Desktop, Documents or Downloads can only follow that step. A refused
  read is a sentence pointing at Privacy & Security, never a retry.
- **Browsing lists one folder, and searching below it holds nothing past the visit.** The folder on
  screen is one `contentsOfDirectory` call and nothing computes a size. Typing reads the names below it
  into a `FileTreeIndex` — UTF-8 back to back, with start offsets, parent links and a folder flag, about
  30 bytes an item, capped at 100,000 items and one second — which is dropped, with
  `malloc_zone_pressure_relief`, the moment the folder changes, the browser is left or the palette
  hides. Each folder read drains its own autorelease pool, and the walk queues folders by index, so
  no `URL` and its cached attributes outlive the read that found them.
- **A superseded query never publishes.** The session cancels its pending task and checks cancellation
  after the synchronous Spotlight call, so a late result cannot replace the newer query's rows. Editing
  the scopes or the patterns cancels the session for the same reason: a result found under the old
  rules must not land under the new ones.
- **Share is the one system popover, and the palette stays up under it.** `AGENTS.md` keeps Tinycast's
  own dialogs because a question or a report is Tinycast's to word. A share sheet is neither: it is
  AirDrop, Mail and Messages, and re-drawing it would mean re-implementing the transports and losing
  whatever the system adds. So this row hands off, and the two rules it does keep are that the palette
  is never hidden and that the row stays visible beside the sheet — which is what anchoring to
  `PaletteWindowController.anchorView` buys. The picker is retained on the coordinator, because it
  dies with its last reference, and `NSItemProvider(contentsOf:)` failing (a file that vanished between
  the query and the keystroke) leaves the palette exactly as it was, which is the only failure this row
  can have.

## Query path

`FileSearchQuery` trims and tokenizes input on whitespace, escapes Spotlight metacharacters, and builds
one `kMDItemFSName` clause per term. The clauses are joined with AND, so `annual report` requires both
words in the filename without requiring them to be adjacent or in that order. The active filter's
`kMDItemContentTypeTree` clause joins them, ahead of the ignore-list exclusions.

`FileSearchSession.search` retains the previous rows, debounces for 120 ms, then drives
`FileSearchService.search` in a detached user-initiated task. One worker serializes synchronous
Spotlight calls and coalesces changes to the newest pending query, so slower typing cannot accumulate
overlapping queries. The session owns *when* a search runs and nothing else — the expressions are the
service's, built where the policy that shapes them already is. The service resolves the configured roots,
then keeps every `MDQuery` reference inside one nonisolated synchronous function. Spotlight returns at
most `FileSearchPolicy.candidateLimit` candidates. `FileSearchQuery` removes hidden path components and
app-bundle contents, applies the ignore list, then applies `FuzzyMatch` and publishes at most the
policy's `resultLimit`. Localized filename then path order makes ties deterministic.

**Searching file contents is a second pass, off by default.** With **Search file contents** on, the
session publishes the filename matches first, then — unless a newer keystroke is already waiting, the
query is blank, or the names already fill the limit — runs `FileSearchService.contentSearch`, whose
`FileSearchQuery.contentExpression` asks for a word starting with each term in `kMDItemTextContent`,
`kMDItemTitle`, `kMDItemKeywords` or `kMDItemDescription` (`"term*"cdw`), under the same filter and
ignore exclusions. Its new paths are merged with the published names and ranked again: a content hit
whose name does not match scores nothing, so it lands after every filename match rather than among
them. The merge publishes only while the request and revision are unchanged, so a superseded query's
content matches never appear, and a content pass that fails leaves the filename rows standing.

**`kMDItemPath` is the only attribute read from a result.** `MDQuery` hands the path back from its own
cache; every other attribute is a metadata fetch costing about half a millisecond, which over a thousand
candidates was the whole of the old latency — a broad query spent a full second fetching content types
alone. What a row needs beyond the path (is it a folder, is it hidden, is it an application) comes from
one `resourceValues` stat, taken only for candidates the ignore list did not already drop. Measured on
the developer home: 200 URLs stat in 13 ms, where 200 metadata fetches cost 200 ms.

Visible files and document packages directly under home are matched locally with the same case- and
diacritic-insensitive all-terms rule, since scoping Spotlight to home itself would pull in `~/Library`.

## Recently used

An empty query is a request of its own, and it skips the typing debounce — there is no next keystroke for
it to coalesce with. `FileSearchQuery.RecentStamp` names the two stamps it asks about, each with its own
window: changed in the last 3 days, used in the last 30. Both are needed because macOS writes
`kMDItemLastUsedDate` for very few opens now — a used-only list is a handful of downloads — and the
shorter change window is what keeps a busy machine's matches under the candidate cap.

Spotlight sorts on one attribute, so the service runs **one sorted query per stamp** and merges their heads
by date, newest first, before publishing 20. Only the first 20 rows of each list are dated: no row past
that can reach the merged list, and every date read costs a metadata fetch. The sort attribute has to be
named in `MDQueryCreate`; set afterwards through `MDQuerySetSortOrder` it is ignored, which is what the
first attempt at this measured.

## Type filter

`FileSearchFilter` is the header's **All Types** pop-up: All Types, Folders, Documents, Images, Audio,
Videos, Archives. Each case names the `UTType`s it admits, and everything else is derived from that list —
the Spotlight clause (`kMDItemContentTypeTree == "public.image"`, parenthesized when a case names several)
and `accepts(contentType:isDirectory:)`, which the home-root branch uses because it never reaches
Spotlight. A type resolved from disk answers both, so a `.pages` package files under Documents and a plain
folder under Folders.

The filter lives on `PaletteState` beside the clipboard's, is reset on every summon, and is never
persisted. ⌘P and the header button open it through `PaletteFilterAction` and the one `PopoverMenu` path
`RootPaletteView` uses for every in-window menu; changing it resets the selection, snaps the scroll and
re-runs the query.

## Scopes and ignore patterns

`FileSearchPolicy` is the resolved answer to "what does this scope list mean": it splits the configured
roots into the ones Spotlight takes verbatim and the home root that has to be expanded, and it compiles
the ignore list. It is rebuilt when either setting changes, never per keystroke, so glob compilation and
tilde expansion stay off the typing path.

Scopes are stored tilde-abbreviated in `fileSearchScopes` so a backup taken on one machine still points
somewhere on another. Home expands into its visible children plus `Library/CloudStorage` and the current
iCloud Drive root; every other root is handed to `MDQuerySetSearchScope` as it stands. An empty list
searches nothing rather than falling back to home — a cleared list is a deliberate choice, not an unset one.

`FileSearchIgnoreList` compiles each pattern once into one of three buckets, which is what keeps matching
cheap enough to run against every candidate:

| Pattern shape | Matched against | Example |
| --- | --- | --- |
| no `/`, no metacharacters | any path component, case-folded, via a `Set` | `node_modules` |
| no `/`, has `*` `?` `[` | any path component, via `fnmatch` | `*.tmp` |
| contains `/` | the whole absolute path, via `fnmatch` | `**/[Cc]ache/**` |

`fnmatch` runs with `FNM_CASEFOLD` and deliberately **without** `FNM_PATHNAME`, so `*` spans `/` and a
`**/…/**` pattern behaves as written. Patterns are stored pre-terminated as `ContiguousArray<CChar>`, so
the hot path never re-encodes a `String` into a temporary C buffer.

Bare `*` name globs are also pushed into the Spotlight expression as `kMDItemFSName != "…"cd` clauses, so
ignored files cannot consume the 1,000-candidate cap. Only that shape is pushed: Spotlight reads `?` and
`[` literally, and `kMDItemPath` is not queryable at all, so path globs have no server-side spelling and
stay local. Quotes and backslashes are escaped on the way in, and any pattern still carrying one is kept
out of the expression — an unescaped pattern would otherwise nil `MDQueryCreate` and break every search
until it was deleted.

The synchronous API cannot stop mid-call. A superseded result is discarded through the session's
revision check, then the same worker runs only the newest pending query. Leaving or hiding the screen
cancels and clears the session as well.

`FileSearchService.search` emits a `FileSearchService.search` interval on the shared
`com.tinycast.perf` signpost subsystem. `Tests/file-search-performance.swift` exercises the same service
against the current user's Spotlight index and reports first-run and repeated-query latency; it stays
outside `run-tests.sh` because filesystem contents and Spotlight state are machine-dependent.

The 2026-09-12 baseline used a release-optimized standalone process against the developer home, after
the path-only rewrite above. The blank screen's recents took 41 ms on a repeat and 184 ms cold; across
`a`, `e`, `swift`, `pdf` and `project` on the shipped settings, first runs took 88–397 ms and repeated
medians 54–107 ms. The 2026-08-11 measurement of the same queries, when every candidate's content type
and invisible flag were fetched, was 192–831 ms first and 191–668 ms repeated. The benchmark runs every
query twice, once on the shipped rules and once with five extra user patterns, and the second pass is
within a few ms — so pattern matching is not where the time goes. The palette's debounce adds 120 ms
before a typed query's measured interval and nothing before the recents one. These are local orders of
magnitude, not budgets; rerun the benchmark after query-policy work.

## Palette and actions

`FileSearchScreen.rows` is the exact flat selection order rendered by `FileSearchList`. Results sit in a
290pt column beside a preview pane, split by the same `Theme.Colors.separator` hairline the clipboard
draws. The list uses the shared Results header, row metrics, edge dissolve, thin scrollbar and scroll
intent; its header reads **Recently Used** on the blank screen and **Results** under a query. A row shows
a fitted native file icon and the full filename — a folder prefixed by its parent's name, dimmed, since
half the folder hits on a developer machine are some `src` or `Tinycast`. The path itself is the preview's
`Where` row rather than a second column the narrow list has no width for. A click selects and a double
click opens, both through `onRowClick`, which answers on the press: `.onTapGesture(count: 2)` makes the
single tap wait out the system's double-click interval first, and that wait *is* the second a click used
to take before the preview moved.

Fitted row icons use a separate 8 MB transient cache. Leaving the list or hiding the palette purges it
and invalidates in-flight decodes, so scrolling stays warm within one result set without retaining its
icons after File Search closes. Persistent launcher icons remain in their own cache.

The preview pane is the file itself over an Information block — Name, Where, Type, Size, Created,
Modified. The stage is **16:9 and sized before the block beneath it**, which then scrolls in whatever is
left; without that layout priority the aspect ratio shrinks to the leftover height instead of claiming
it. `FileSearchPreviewKind` picks what draws the file, and `FileSearchSurface` mounts it:

| Kind | Surface | Why not QuickLook |
| --- | --- | --- |
| movies, audio | `FileSearchMediaPlayer` | it draws a movie's first frame but never plays one inside a non-activating panel |
| PDF | `PDFSurface`, PDFKit in process | it draws a PDF in an out-of-process `NSRemoteView` that never scrolls inside the palette |
| text QuickLook shows as an icon | `PlainTextSurface` | it renders only a declared `public.text` type as text |
| everything else | `QuickLookSurface` | — |

The extension decides without touching the disk, except where it cannot: an undeclared extension
(`.jsx`, `.vue`) or `.ts`, which the system declares as MPEG-TS video. Those read their first 256 KB
off the main actor once per selection — no NUL and valid UTF-8 is text, anything else falls back to
what the extension declares. `PlainTextSurface` copies QuickLook's own text preview (fixed-pitch 11pt,
3pt inset, unselectable), so a `.jsx` reads like a `.swift`.
**Only the ⌘Y overlay autoplays.** `autoplays` is the surface's one parameter and the pane leaves it
off: arrow-keying a list must not start a movie, while opening Quick Look on one is the ask itself.
The player view is `KeyboardFocusRefusing` either way, so clicking its transport leaves the caret in
the search field; see [palette.md](palette.md#the-keyboard-belongs-to-the-search-field).
The player is File Search's own, deliberately: the clipboard's preview is a separate surface with its own
sizing, and copying forty lines of `AVPlayerView` teardown is the cheaper trade.

**The surface outlives the selection**, and there is no timer in front of it. A move hands the same
`QLPreviewView` another item rather than closing one and building the next, which is the whole cost:
measured against the real machinery inside a panel shaped like the palette's — borderless, floating,
non-activating — a swap paints in about 8 ms, and the first load in a process in about 130 ms. Nothing
about that is worth debouncing, and the debounce that was there only made a click feel slow. The surface
is torn down by not being mounted: when the palette is ordered out, when the ⌘Y overlay covers it, or on
a folder, whose preview is its icon. Information rows are the compact variant; their disk reads happen once per selection
in a detached task, never in `body`, and a folder shows no Size — its own record is a few bytes, which is
never what the row means.

Quick Look (⌘Y) draws **inside the panel**: the palette hides itself on `windowDidResignKey` and the panel
is non-activating, so a system `QLPreviewPanel` would take key and close the palette under itself.
`FileSearchQuickLook` hosts the same two surfaces the pane does, following the selection. **Escape is
answered by `PalettePanel.onEscape`**, not by the palette's own key handler: a focused `AVPlayerView`
takes the key window's Escape first, and `sendEvent` is the one place ahead of it. **Only the margin
around the card dismisses on a click** — a tap over the preview belongs to the preview's own transport,
and a dismissing gesture laid over the whole overlay swallowed the play button — so the Close button is
the pointer's way out. Its corners are concentric, each radius the one outside it less its own inset, and
the overlay is cleared whenever the palette is ordered out: the tree stays mounted, and a preview must
not outlive the window.

| Row | Chord | What it does |
| --- | --- | --- |
| Open File / Open Folder | ↵ | `NSWorkspace`'s asynchronous configuration API; hides the palette without restoring focus, and reports a failure through the dialog controller |
| Show in Finder | ⌘↵ | reveals and dismisses |
| Show Info in Finder | ⇧⌘I | `AppLauncher.showInfoInFinder`, the same Apple-events route Uninstall uses; hides the palette, and a refused Automation grant reports through a notice |
| Quick Look | ⌘Y | the in-panel overlay above |
| Share… | — | `NSSharingServicePicker`, anchored to the palette's trailing edge so the row it was opened from stays visible beside it. Escape or a click elsewhere dismisses it, and the palette is never hidden, so the flow returns to the same row. There is no chord: the destinations are the system's, and it is the only place a system popover is right |
| Save as Quicklink | ⌘S | hides the palette and opens Settings ▸ Quicklinks with the editor prefilled — the file's name and its `file://` URL — so the user names and saves it there |
| Copy File | ⇧⌘C | the file itself on the pasteboard through `PasteboardFiles.write`, which declares `.fileURL` and the path as `.string` |
| Copy Name | ⌥⌘C | through `Paster`, palette stays open |
| Copy Path | ⌃⌘C | the standardized path, palette stays open |
| Paste File to … | ⇧⌘V | `Paster.pasteFile` into the app the palette was summoned over, named by `PasteTarget` |
| Move to Trash | ⌃X | `FileManager.trashItem` off the main actor, then the row leaves the session |

None of the copies is marked with `ClipboardManager.internalType`, so a copied file enters clipboard
history like any other copy. Move to Trash rides the clipboard's own ⌃X, asks nothing first — trashing is
undoable, as it is for Uninstall and for an extension's `trash` — and has no ⌃⇧X counterpart, since there
is no "all" to trash. The three ⌘C chords differ only by their second modifier, which
`PaletteShortcut` reads in order — ⇧, then ⌥, then ⌃; bare ⌘C stays with the search field.

The first in-flight query says nothing — the rows it is about to replace would only flash a message — an
empty completed query says what the active filter admits ("No files found", "No images found"), a blank
screen with no recents says "Type to search files and folders", and query creation or execution failure
says "File search is unavailable" inline.

### Dragging out

A row drags its file or folder straight into another app — a Finder window, a browser's upload field,
a mail being written — through the same `onRowClick(drag:)` the clipboard uses, so the press, the
**copy-only** operation and the fly-back are the ones [clipboard.md](clipboard.md#dragging-out)
explains. Copy matters more here than there: every result is the user's own file, and on the boot
volume a plain file-URL drag would default to moving it. The image is the row's fitted tile, already
warm by the time a pointer can reach it; a landed drop hides the palette through
`PaletteCoordinator.dragLanded()`. There is no stat first: a result is seconds old, and its session is
cleared whenever the palette hides.

## Browsing

**Browse Files** (a command with its own shortcut) opens the same split — `FileSearchList` beside
`FileSearchPreview`, the in-panel Quick Look over both — on one folder at a time, starting at home.
Typing `~` or `/` into the launcher does the same at that path (`FileBrowserPath.starts`), pushed over
the launcher so Escape walks back to it; **Browse from the launcher** in Settings › File Search ›
Browsing turns that off, and the whole feature follows `fileSearchEnabled`.

The field is a filter of the folder on screen. `FileBrowserPath.walk` reads a typed path: `~` and `/`
restart from home or the root, `..` goes up, each segment followed by `/` that names a folder walks
into it, and what is left filters — `~/Dev/ti` lands in `~/Dev` filtering by `ti`, and a segment that
is no folder stops the walk and stays in the filter. A walk leaves only the filter in the field.

→ opens the selected folder and ↵ does too; a file opens as a search result does. ← goes up while the
field is empty (with text it moves the caret), and a bare backspace goes up until home, then leaves
the browser — from `/` or a folder outside home it leaves at the root. Going up lands the highlight on
the folder just left. ⌘↵ shows in Finder, ⌘Y is Quick Look, and ⌘K adds Copy Path, Copy Name and the
two view toggles. Renaming, moving and trashing are Finder's: Show in Finder is the way there.

⇥ completes like a shell: first to the longest prefix every name in the folder starting with the
typed text shares (`dev` → `Develop`, `FileBrowserCompletion`), then to the highlighted row — a folder
is walked into, a file's name fills the field. ⇧⇥ goes up. **Space looks, as in Finder**, while
**Space opens Quick Look** (`fileBrowserSpaceQuickLook`, on) is on: with the field empty, or once
the highlight has been moved by an arrow or a click, a bare Space toggles Quick Look — caught in
`PalettePanel.sendEvent` before the field editor can type it. Typing any other character hands Space
back to the field (`PaletteState.browseSpaceLooks`), so `annual report` still types its space. Escape
clears typed text, then returns to the root search whatever the configured Escape behavior
(`PaletteEscapeAction.returnToLauncher`): the browser is a place reached from the launcher, so leaving
it never closes the palette.

### Searching below a folder

Text that is not a path searches the folder on screen and everything below it. The folder's own
items rank at once, by `FileNameScore`; after an 80 ms pause the subtree answers and replaces them.
`FileNameScore` is the launcher's fuzzy tiers — exact, prefix, word start, substring, letters in order
— with one change for names: among letters-in-order hits, the tightness bonus counts four times and
the name's length is subtracted, so between equally tight hits the shorter name wins, while letters
landing on word starts still read as initials (`tcfg` → `the_list_that_cut_forecast_go…`). Ties go to
the shallower item, then to the name.

`FileTreeIndexer` reads the subtree on the first keystroke, breadth first, skipping hidden items
unless shown, packages' insides and the excluded folders; it never enters Desktop, Documents,
Downloads, `~/Library` or iCloud Drive from above, since a walk is no step the user took. Every later
keystroke ranks what is already in memory: on the developer's `~/Development`, 60,133 items took
650–730 ms to read once and 2–4 ms a query (43 ms for a single letter). Home, `/` and the folders above
home are never walked — `FileTreeIndexer.walks` — and a walk that hit its cap or its second is
incomplete: both are answered by `FileSearchService.subtree`, a Spotlight query for every typed letter
in order (`kMDItemFSName == "*t*c*f*g*"cd`, `FileSearchQuery.subsequenceExpression`) under that
folder, with the ignore list and the browser's own exclusions applied, ranked by the same score. Rows
below the folder name the folders between, dimmed (`Swift/tinycast/README.md`), and ⇥ on a deep folder
walks straight into it.

`FileBrowserListing` orders folders first, then names as Finder sorts them, and caps a folder at
2,000 rows, heading the list with how many more a filter would reach. Hidden items stay out unless
**Show hidden files** (`fileBrowserShowsHidden`) is on. Folders the ignore list names — File Search's
own patterns, the shipped defaults included, plus `.git`, `.venv`, `__pycache__`, `.next`, `.cache` and
`.Trash` — are counted in the list's header rather than listed, by their own name only, so a folder
the user walked into on purpose lists everything inside it; ⌘K's Show Excluded Folders lists them in
place for that folder. A package is a file here: an `.app` opens rather than being walked into. A
read that lands after the user has moved on is dropped by a generation check.

## Invocation

Settings ▸ File Search owns the `fileSearchEnabled` switch, which is off when its preference is absent,
along with the scope list, the ignore patterns, the Search Files command row, and a Results section with
**Search file contents** (`fileSearchIncludesContent`, off) and **Maximum results**
(`fileSearchResultLimit`, 200), and a Browsing section with **Browse from the launcher**
(`fileBrowserFromLauncher`, on), **Show hidden files** (`fileBrowserShowsHidden`, off) and **Space opens
Quick Look** (`fileBrowserSpaceQuickLook`, on). All of them are
ordinary settings carried by Tinycast settings backups; importing them grants no permission or
background access.

`AppCore` observes the switch and asks `FileSearchCoordinator` to project `CommandID.searchFiles` into
the launcher; a second observation rebuilds the policy when either list changes. The coordinator also
guards entry into `.fileSearch`, so neither a stale selected command nor the global shortcut can open
the screen after the feature is disabled. Disabling cancels the session and returns an open File Search
screen to the launcher without changing palette visibility.

Search Files is bindable like every other built-in command — `AppEntry.hotKeyAction` answers
`.command(.searchFiles)`, so its launcher row prints a bound chord as a keycap.

This pane is the command's only one: `SettingsTab.ownedCommands` names it, so Settings ▸ Commands
neither lists it nor gates it behind `Enable Commands`. Launcher visibility is `VisibilityStore`'s,
keyed on the entry's `preferenceKey`. The entry behind it comes from
`CommandCatalog.entry(for:)` rather than `AppIndex`, because the index drops the command entirely while
the feature switch is off — exactly when the pane still has to draw the row. Hiding the command leaves
the shortcut working, as it does for every other feature.
