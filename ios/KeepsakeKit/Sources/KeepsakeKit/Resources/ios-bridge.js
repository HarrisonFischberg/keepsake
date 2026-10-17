// iOS backends for Keepsake's shared store (keepsake/src/shared/storage.js), on top of the native
// SQLite bridge in RecordDatabase.swift. Loaded after keepsake-core.js.
//
// __native.db (synchronous; strings in and out, JSON for records):
//   all(store) → "[...]"             get(store, key) → "{...}" | null
//   byIndex(store, index, value) → "[...]"   count(store) → number
//   put(store, "[recordJSON, …]") → ""|error       remove(store, "[keys]") → ""|error
//   swap(store, "[[key, expectedBodyOrNull, nextBodyOrNull], …]") → ""|"conflict"|error
//   clear("[stores]") → ""|error
// __native.kv: get("[keys]") → "{...}", set("{...}") → ""|error, remove("[keys]"), clear()

(function () {
  const S = KeepsakeCore.storage;
  const check = (r) => {
    if (r === '' || r === undefined || r === null) return;
    if (/full|SQLITE_FULL/i.test(r)) throw new S.StorageFullError();
    throw new Error(r);
  };

  // The card's key fact for a save (kinds.js keyFact), stored beside it so screens never call JS to draw a card.
  const factOf = (item) => {
    try { return KeepsakeCore.kinds.keyFact(item, { formatPrice: KeepsakeCore.util.formatPrice }) || ''; } catch { return ''; }
  };
  const row = (store, r) => (store === 'items' ? [JSON.stringify(r), factOf(r)] : JSON.stringify(r));

  function nativeRecordBackend() {
    const n = __native.db;
    const listeners = new Set();
    const emit = (stores) => listeners.forEach((fn) => fn({ stores }));
    return {
      kind: 'sqlite',
      async all(store) { return JSON.parse(n.all(store)); },
      async get(store, key) { const s = n.get(store, String(key)); return s == null ? undefined : JSON.parse(s); },
      async byIndex(store, index, value) { return JSON.parse(n.byIndex(store, index, value == null ? '' : String(value))); },
      async count(store) { return n.count(store); },
      async put(store, records) { if (!records.length) return; check(n.put(store, JSON.stringify(records.map((r) => row(store, r))))); emit([store]); },
      async remove(store, keys) { if (!keys.length) return; check(n.remove(store, JSON.stringify(keys))); emit([store]); },
      // Atomic read-modify-write: read, apply fn, then write only if nothing changed underneath
      // (another process, e.g. the Share Extension, may have written). Retries on conflict.
      async update(store, keys, fn) {
        for (let attempt = 0; attempt < 8; attempt++) {
          const ops = [];
          const results = [];
          for (const key of keys) {
            const raw = n.get(store, String(key));
            const next = fn(raw == null ? undefined : JSON.parse(raw));
            if (next === undefined) continue;
            if (next === null) { if (raw != null) ops.push([String(key), raw, null]); continue; }
            ops.push([String(key), raw == null ? null : raw, JSON.stringify(next), store === 'items' ? factOf(next) : null]);
            results.push(structuredClone(next));
          }
          if (!ops.length) return results;
          const r = n.swap(store, JSON.stringify(ops));
          if (r === 'conflict') continue;
          check(r);
          emit([store]);
          return results;
        }
        throw new Error('Keepsake could not save because the library kept changing. Try again.');
      },
      async clear(stores) { check(n.clear(JSON.stringify(stores))); emit(stores); },
      onChanged(fn) { listeners.add(fn); return () => listeners.delete(fn); },
    };
  }

  function nativeKvBackend() {
    const n = __native.kv;
    const listeners = new Set();
    return {
      async get(keys) {
        const list = keys == null ? null : Array.isArray(keys) ? keys : [keys];
        return JSON.parse(n.get(JSON.stringify(list)));
      },
      async set(obj) { check(n.set(JSON.stringify(obj))); const changes = {}; for (const k of Object.keys(obj)) changes[k] = { newValue: obj[k] }; listeners.forEach((fn) => fn(changes)); },
      async remove(keys) { check(n.remove(JSON.stringify(Array.isArray(keys) ? keys : [keys]))); },
      async clear() { check(n.clear()); },
      onChanged(fn) { listeners.add(fn); return () => listeners.delete(fn); },
    };
  }

  globalThis.store = S.createStore(nativeKvBackend(), nativeRecordBackend());

  // A save from the Share Sheet: Chrome's capture rules (src/shared/capture.js), same as the toolbar.
  // The after-save fill-in (AI, Lookups) isn't wired on iOS yet, so its hooks do nothing.
  globalThis.capture = (product, options) => KeepsakeCore.capture.saveCapture(store, product, options || {});

  // Fills in key facts for saves stored without one (older rows). Run once when the library opens.
  globalThis.backfillFacts = () => {
    const missing = JSON.parse(__native.db.missingFacts());
    if (!missing.length) return 0;
    const facts = {};
    for (const item of missing) facts[item.id] = factOf(item);
    check(__native.db.setFacts(JSON.stringify(facts)));
    return missing.length;
  };

  // What the screens list, decided by Chrome's own functions (the dashboard does the same).
  const K = KeepsakeCore;
  const withFact = (i) => ({ ...i, fact: factOf(i) });
  globalThis.views = {
    // Review: saves that need a collection and aren't bought (dashboard.js: needsCollection && isActive).
    async review() {
      return (await store.getItems()).filter((i) => K.kinds.needsCollection(i) && !i.purchased).map(withFact);
    },
    async ofKind(kind) {
      return (await store.getItems()).filter((i) => i.kind === kind).map(withFact);
    },
    async inCollection(collectionId) {
      return (await store.getItems()).filter((i) => i.collectionId === collectionId).map(withFact);
    },
    // Search: ranked, forgives a typo (search.js), collection names count as text.
    async search(query) {
      const [items, cols] = await Promise.all([store.getItems(), store.getCollections()]);
      const names = new Map(cols.map((c) => [c.id, c.name]));
      const r = K.search.searchItems(items, query, (i) => names.get(i.collectionId) || '');
      return { items: r.results.map((x) => withFact(x.item)), query: r.query, corrected: r.corrected };
    },
    // Places: ready ones by state then city (dashboard.js renderPlaceList); the rest wait in Places review.
    async places() {
      const all = (await store.getItems()).filter((i) => i.kind === 'place');
      const review = [];
      const states = new Map();
      for (const item of all) {
        const reasons = K.places.placeReviewReasons(item);
        if (reasons.length) { review.push({ item: withFact(item), reasons }); continue; }
        const st = K.places.placeState(item)?.name || 'Somewhere';
        const city = String(item.details?.locality || '').trim();
        if (!states.has(st)) states.set(st, new Map());
        const cities = states.get(st);
        if (!cities.has(city)) cities.set(city, []);
        cities.get(city).push(item);
      }
      const byName = (a, b) => (a.status === 'done') - (b.status === 'done') || a.title.localeCompare(b.title);
      const groups = [...states.keys()].sort((a, b) => a.localeCompare(b)).map((state) => {
        const cities = states.get(state);
        return {
          state,
          cities: [...cities.keys()].sort((a, b) => (!a) - (!b) || a.localeCompare(b)).map((city) => ({ city, items: cities.get(city).sort(byName).map(withFact) })),
        };
      });
      return { groups, review };
    },
    // Where a save can go: the Lifestyle views, then collections (pinned first, then most used), as in
    // Chrome's pickers ("kind:place" means the Places view).
    async destinations() {
      const [cols, items] = await Promise.all([store.getCollections(), store.getItems()]);
      const counts = new Map();
      for (const i of items) if (i.collectionId) counts.set(i.collectionId, (counts.get(i.collectionId) || 0) + 1);
      const ordered = [...cols].sort((a, b) => (b.pinned === true) - (a.pinned === true) || (counts.get(b.id) || 0) - (counts.get(a.id) || 0) || a.name.localeCompare(b.name));
      return [
        ...K.kinds.LIFESTYLE().map((k) => ({ value: `kind:${k.value}`, label: k.plural, group: 'lifestyle', kind: k.value })),
        ...ordered.map((c) => ({ value: c.id, label: c.name, group: 'collection', kind: null })),
      ];
    },
    // Puts saves where you chose (dashboard.js putItems): a Lifestyle view (each becomes that kind, its
    // details worked out from what it holds) or a collection (a Lifestyle save going there becomes
    // something to buy). Returns where they went, for the toast.
    async put(ids, target, learn) {
      const items = (await Promise.all(ids.map((id) => store.getItem(id)))).filter(Boolean);
      if (target.startsWith('kind:')) {
        const kind = target.slice(5);
        for (const it of items) await store.updateItem(it.id, K.kinds.kindChangePatch(it, kind, { yours: true }), { by: 'kind' });
        return K.kinds.kindInfo(kind).plural;
      }
      for (const it of items) if (K.kinds.hasOwnView(K.kinds.kindOf(it))) await store.updateItem(it.id, { kind: K.kinds.shoppingKindFor(it), details: {} }, { by: 'kind' });
      await store.moveItems(items.map((i) => i.id), target, { learn: learn || 'light' });
      const col = await store.getCollection(target);
      return col ? col.name : 'collection';
    },
    // Everything a save's own screen needs, formatted by Chrome's code: exercises (formatExercise),
    // goals with progress, the maps links (mapsLinks: built from what's saved, nothing looked up).
    async detail(id) {
      const item = await store.getItem(id);
      if (!item) return null;
      const d = item.details || {};
      const out = { item: withFact(item), exercises: [], goals: [], maps: null, time: '' };
      if (item.kind === 'workout') {
        out.exercises = (d.exercises || []).map((e) => K.kinds.formatExercise(e));
        out.goals = await this.goals(id);
      }
      if (item.kind === 'place') out.maps = K.kinds.mapsLinks(item.title, d);
      if (item.kind === 'recipe') out.time = K.kinds.formatMinutes(d.totalMinutes);
      // Where the card's details came from (dashboard.js's labels), and what your AI provider drafted
      // because the save didn't say it ("AI draft" beside those headings).
      const SOURCE = {
        recipe: { page: 'Recipe from the page', caption: 'Recipe from the caption', you: 'Recipe added by you', ai: 'Recipe read by AI', 'ai-draft': 'Drafted by AI: check it before you cook' },
        workout: { page: 'Exercises from the page', caption: 'Exercises from the caption', you: 'Exercises added by you', ai: 'Exercises read by AI', 'ai-draft': 'Exercises drafted by AI: check them before you train' },
        place: { page: 'Details from the page', 'maps-link': 'From a maps link', you: 'Added by you', ai: 'Details found by AI' },
      };
      out.sourceLabel = SOURCE[item.kind]?.[d.source] || '';
      out.drafted = Array.isArray(d.drafted) ? d.drafted : [];
      return out;
    },
    // What the widgets show, worked out here so the widget process never runs this code: active goals
    // with their week (goalProgress), the latest save, and one to come back to.
    async widgetSnapshot() {
      const items = await store.getItems();
      const byId = new Map(items.map((i) => [i.id, i]));
      const goals = [];
      for (const g of await store.getGoals()) {
        const item = byId.get(g.itemId);
        if (!item) continue;
        const p = K.goals.goalProgress(g, await store.getCheckins(g.id));
        if (p.status !== 'active') continue;
        goals.push({ goalId: g.id, itemId: item.id, title: item.title, summary: p.summary, ring: p.ring,
          weeks: (p.strip || []).map((w) => ({ week: w.week, met: w.met, count: w.count, target: w.target, current: w.current })) });
      }
      const latest = items[0] ? { id: items[0].id, title: items[0].title, kind: items[0].kind, fact: factOf(items[0]) } : null;
      return { at: new Date().toISOString(), count: items.length, goals, latest };
    },
    // The after-save work Chrome queues right after a save (background.js: AI tidy, Lifestyle fill-in),
    // run here when the app is open. Only what is turned on runs; a save is filled in once.
    async finishSaves() {
      const settings = await store.getSettings();
      const key = await store.getSecret('aiApiKey');
      const aiOn = !!settings.ai?.on && !!key;
      const lookupsOn = Object.values(settings.lookups || {}).some(Boolean);
      const items = await store.getItems();
      let tidied = 0;
      // With AI on, tidySave first has your provider work out what each save is (understand.js).
      for (const it of items.filter((i) => i.captureState === 'pending')) { await K.fill.tidySave(store, it.id); tidied++; }
      if (!aiOn && !lookupsOn) return { tidied, filled: 0 };
      const raw = await store.backend.get(['keepsake_ios_filled']);
      const filled = new Set(raw.keepsake_ios_filled || []);
      // Read again: a save the tidy found to be a recipe or place is filled in now. A save your provider
      // hasn't read yet (you moved it into a Lifestyle view) is filled in again.
      const todo = (await store.getItems()).filter((i) => K.capture.FILLED_KINDS.includes(K.kinds.kindOf(i)) && (!filled.has(i.id) || (aiOn && !i.understoodAt))).slice(0, 20);
      let last = 0;
      const waitTurn = async () => {
        const wait = 1100 - (Date.now() - last);
        if (wait > 0) await new Promise((r) => setTimeout(r, wait));
        last = Date.now();
      };
      for (const it of todo) {
        await K.fill.fillSave(store, it.id, {}, { fetchFn: fetch, allowed: async (s, which) => !!s.lookups?.[which], waitTurn });
        filled.add(it.id);
      }
      await store.backend.set({ keepsake_ios_filled: [...filled].slice(-5000) });
      return { tidied, filled: todo.length };
    },
    // Fix with AI / Read again for one save (Places review): Chrome's fill-in with review on.
    async fixPlace(id) {
      await K.fill.fillSave(store, id, { review: true }, { fetchFn: fetch, allowed: async (s, which) => !!s.lookups?.[which] });
      return withFact(await store.getItem(id));
    },
    async aiLog() { return (await store.getAiLog()).slice().reverse(); },
    // Undo AI changes (dashboard/aiCleanup.js undoEntries): newest first, back to each "before"; a
    // collection deleted since sends the save to Review instead.
    async undoAi(ids) {
      const want = new Set(ids);
      const entries = (await store.getAiLog()).filter((e) => want.has(e.id) && !e.undone).sort((a, b) => (a.at < b.at ? 1 : -1));
      const cols = new Set((await store.getCollections()).map((c) => c.id));
      const done = [];
      for (const e of entries) {
        if (e.goalId) { if (await store.getGoal(e.goalId)) await store.updateGoal(e.goalId, e.before); done.push(e.id); continue; }
        const item = await store.getItem(e.itemId);
        if (item) {
          const restore = { ...e.before };
          if ('collectionId' in restore && restore.collectionId && !cols.has(restore.collectionId)) { restore.collectionId = null; restore.needsReview = true; }
          await store.updateItem(item.id, restore, { by: 'ai' });
        }
        done.push(e.id);
      }
      if (done.length) await store.markAiLogUndone(done);
      return done.length;
    },
    // Optional AI is on and a key is set: the AI buttons show.
    async aiReady() {
      const settings = await store.getSettings();
      return !!settings.ai?.on && !!(await store.getSecret('aiApiKey'));
    },
    // Fix with AI for saves in Review (dashboard/aiCleanup.js runAiCleanup, scope 'review', planFixes):
    // each save's title, description (an Instagram post's caption) and current collection go to your
    // provider in batches; a confident answer files it, tidies a product's title and price, and logs the
    // change with Undo. Hand-edited fields stay. No live pages are read on iOS.
    async fixWithAI(ids) {
      const settings = await store.getSettings();
      const key = await store.getSecret('aiApiKey');
      if (!settings.ai?.on || !key) throw new Error('Turn on Optional AI and add your key first.');
      const prefs = await store.getPrefs();
      const threshold = prefs.confidenceThreshold || 0.6;
      const FIELDS = ['title', 'price', 'currency', 'collectionId', 'needsReview', 'categorizationSource', 'categorizationReason', 'confidence', 'previousCollections'];
      const report = { checked: 0, changed: 0, filed: [], error: '' };
      const runId = `ios-fix-${Date.now()}`;
      const found = (await Promise.all(ids.map((id) => store.getItem(id)))).filter((i) => i && !i.deletedAt);
      // What each save is, first (Chrome's Fix with AI, understand.js): a recipe, workout or place goes to
      // its Lifestyle view with its details; the rest get the shopping check below.
      const items = [];
      for (const it of found) {
        let r = null;
        try {
          r = await K.understand.understandItem(store, it.id, { force: true, runId });
        } catch (e) {
          report.error = String((e && e.message) || e);
          if (/\((401|403|429)\)|API key|base URL/i.test(report.error)) return report;
        }
        if (r && K.kinds.hasOwnView(r.kind)) {
          report.checked++;
          if (r.changed) {
            report.changed++;
            report.filed.push({ id: it.id, collection: K.kinds.kindInfo(r.kind).plural });
          }
        } else items.push((await store.getItem(it.id)) || it);
      }
      report.logIds = (await store.getAiLog()).filter((e) => e.runId === runId).map((e) => e.id);
      for (let at = 0; at < items.length; at += K.provider.CLEANUP_BATCH) {
        const batch = items.slice(at, at + K.provider.CLEANUP_BATCH);
        const collections = await store.getCollections();
        const entries = batch.map((item, n) => {
          const col = item.collectionId ? collections.find((c) => c.id === item.collectionId) : null;
          return { ref: `i${n}`, item: item.instagram?.caption ? { ...item, description: item.instagram.caption } : item, live: null, currentCollection: col ? col.name : '' };
        });
        let results;
        try {
          results = await K.provider.cleanupWithAI(entries, collections, settings, key);
        } catch (e) {
          report.error = String((e && e.message) || e);
          break;
        }
        const log = [];
        for (let n = 0; n < batch.length; n++) {
          const ai = results.get(`i${n}`);
          if (!ai) continue;
          report.checked++;
          const item = (await store.getItem(batch[n].id)) || batch[n];
          const mine = new Set(item.userFields || []);
          const patch = {};
          const changes = [];
          if (item.type === 'product') {
            if (ai.title && ai.title !== item.title && !mine.has('title')) { patch.title = ai.title; changes.push({ field: 'title', from: item.title, to: ai.title }); }
            const currency = ai.currency || item.currency || '';
            if (ai.price !== null && ai.price !== undefined && !mine.has('price') && (ai.price !== item.price || (ai.currency && ai.currency !== item.currency))) {
              patch.price = ai.price;
              patch.currency = currency;
              changes.push({ field: 'price', from: K.util.formatPrice(item.price, item.currency) || 'none', to: K.util.formatPrice(ai.price, currency) });
            }
          }
          if (ai.collectionId && ai.collectionId !== item.collectionId && K.kinds.needsCollection(item) && ai.confidence >= threshold) {
            Object.assign(patch, { collectionId: ai.collectionId, needsReview: false, categorizationSource: 'ai', confidence: ai.confidence, categorizationReason: `AI: ${ai.reason || 'best match'}` });
            changes.push({ field: 'collection', fromId: item.collectionId || null, toId: ai.collectionId, to: ai.collectionName });
            report.filed.push({ id: item.id, collection: ai.collectionName || '' });
          }
          if (!changes.length) continue;
          const before = {};
          for (const f of FIELDS) if (f in patch) before[f] = item[f] === undefined ? null : item[f];
          await store.updateItem(item.id, patch, { by: 'ai' });
          report.changed++;
          log.push({ id: K.util.uid(), runId, at: K.util.nowIso(), itemId: item.id, itemTitle: patch.title || item.title, changes, before, after: patch, reason: ai.reason || '', undone: false });
        }
        if (log.length) await store.appendAiLog(log);
        report.logIds = [...(report.logIds || []), ...log.map((e) => e.id)];
      }
      return report;
    },
    async testAi() {
      const settings = await store.getSettings();
      return K.provider.testConnection(settings, await store.getSecret('aiApiKey'));
    },
    // Review's three suggestions for a save (dashboard.js topSuggestions): the categorizer's best
    // matches first, padded with the collections you file into most.
    async suggestions(id) {
      const [item, collections, prefs, settings, items] = await Promise.all([store.getItem(id), store.getCollections(), store.getPrefs(), store.getSettings(), store.getItems()]);
      if (!item) return [];
      const cls = K.categorizer.classify(item, { collections, prefs, settings });
      const counts = new Map();
      for (const i of items) if (i.collectionId) counts.set(i.collectionId, (counts.get(i.collectionId) || 0) + 1);
      const picks = [];
      const seen = new Set();
      const add = (s) => {
        const key = s.isNew ? `new:${s.taxonomyKey}` : s.collectionId;
        if (!key || seen.has(key) || picks.length >= 3) return;
        seen.add(key);
        picks.push({ value: key, label: s.collectionName, isNew: !!s.isNew });
      };
      for (const a of cls.alternatives || []) if (a.isNew ? a.taxonomyKey : a.collectionId) add(a);
      for (const c of [...collections].sort((a, b) => (counts.get(b.id) || 0) - (counts.get(a.id) || 0))) add({ collectionId: c.id, collectionName: c.name, isNew: false });
      return { reason: item.categorizationReason || cls.reason || '', picks };
    },
    // Files a save from Review (a suggestion may be a collection not created yet: "new:<taxonomy>").
    async file(id, target) {
      let to = target;
      if (to.startsWith('new:')) {
        const col = await store.ensureCollectionForTaxonomy(to.slice(4));
        if (!col) throw new Error('That collection could not be made.');
        to = col.id;
      }
      return this.put([id], to, 'strong');
    },
    // Not sure where a save goes: it waits in Review (no collection, nothing to buy decided yet). A
    // Lifestyle save becomes something to file (shoppingKindFor), since Review holds only those.
    async toReview(ids) {
      for (const id of ids) {
        const it = await store.getItem(id);
        if (!it) continue;
        const patch = { collectionId: null, needsReview: true };
        if (K.kinds.hasOwnView(K.kinds.kindOf(it))) Object.assign(patch, { kind: K.kinds.shoppingKindFor(it), details: {} });
        await store.updateItem(id, patch, { by: 'kind' });
      }
    },
    // Undoing a save that just happened removes it outright (background.js UNDO_SAVE).
    async undoSave(id) { await store.deleteForever([id]); },
    // A workout's goals with their progress (goals.js goalProgress).
    async goals(itemId) {
      const goals = await store.getGoals({ itemId });
      return Promise.all(goals.map(async (g) => ({ goal: g, progress: K.goals.goalProgress(g, await store.getCheckins(g.id)) })));
    },
  };

  // Calls `path` (e.g. "store.importJSON" or "KeepsakeCore.kinds.kindOf") with JSON arguments and
  // reports the JSON result. The only way Swift runs shared code: no string-built scripts.
  globalThis.__call = function (path, argsJSON, ok, fail) {
    Promise.resolve().then(() => {
      const parts = path.split('.');
      let self = globalThis;
      for (const p of parts.slice(0, -1)) self = self[p];
      const fn = self[parts[parts.length - 1]];
      if (typeof fn !== 'function') throw new Error(`No function ${path}`);
      return fn.apply(self, JSON.parse(argsJSON));
    }).then(
      (v) => ok(v === undefined ? 'null' : JSON.stringify(v)),
      (e) => fail(String((e && e.message) || e) + (e && e.name ? `|${e.name}` : '')),
    );
  };
})();
