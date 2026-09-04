/* AiNotetaker — frontend logic. Plain ES, no build step. */
(function () {
  "use strict";

  // ───────────────────────── State ─────────────────────────
  var config = {
    app_title: "Notes",
    auth_required: false,
    authenticated: true,
    transcription_configured: false,
    language: "",
  };
  var notes = [];
  var current = null; // { id, title, content, pinned, ... }
  var isDraft = false;
  var saveTimer = null;
  var searchTimer = null;
  var createPromise = null;

  // ───────────────────────── Elements ──────────────────────
  var $ = function (id) { return document.getElementById(id); };
  var views = { login: $("login-view"), list: $("list-view"), editor: $("editor-view") };

  var loginForm = $("login-form");
  var loginPassword = $("login-password");
  var loginError = $("login-error");
  var logoutButton = $("logout-button");

  var searchInput = $("search-input");
  var notesList = $("notes-list");
  var emptyState = $("empty-state");
  var notesCount = $("notes-count");
  var composeButton = $("compose-button");

  var backButton = $("back-button");
  var pinButton = $("pin-button");
  var deleteButton = $("delete-button");
  var editorDate = $("editor-date");
  var titleInput = $("note-title");
  var bodyInput = $("note-body");

  var micButton = $("mic-button");
  var recStatus = $("rec-status");
  var recText = $("rec-text");
  var recTimer = $("rec-timer");
  var toastEl = $("toast");

  // ───────────────────────── API ───────────────────────────
  async function api(path, options) {
    options = options || {};
    var opts = Object.assign({ credentials: "same-origin" }, options);
    if (opts.body && typeof opts.body === "string") {
      opts.headers = Object.assign({ "Content-Type": "application/json" }, opts.headers || {});
    }
    var res = await fetch(path, opts);
    if (res.status === 401) { onUnauthorized(); throw new Error("unauthorized"); }
    if (!res.ok) {
      var detail = "Request failed";
      try { detail = (await res.json()).detail || detail; } catch (e) {}
      throw new Error(detail);
    }
    if (res.status === 204) return null;
    var ct = res.headers.get("content-type") || "";
    return ct.indexOf("json") !== -1 ? res.json() : res.text();
  }

  function onUnauthorized() {
    config.authenticated = false;
    showView("login");
    setTimeout(function () { loginPassword && loginPassword.focus(); }, 100);
  }

  // ───────────────────────── Views ─────────────────────────
  function showView(name) {
    Object.keys(views).forEach(function (k) { views[k].hidden = true; });
    views[name].hidden = false;
  }

  function applyConfig() {
    var title = config.app_title || "Notes";
    document.title = title;
    $("login-title").textContent = title;
    var big = document.querySelector(".large-title");
    if (big) big.textContent = title;
    logoutButton.hidden = !config.auth_required;
  }

  // ───────────────────────── Login ─────────────────────────
  loginForm.addEventListener("submit", async function (e) {
    e.preventDefault();
    loginError.hidden = true;
    var password = loginPassword.value;
    try {
      await api("/api/login", { method: "POST", body: JSON.stringify({ password: password }) });
      loginPassword.value = "";
      config.authenticated = true;
      await openList();
    } catch (err) {
      loginError.textContent = "Incorrect password. Please try again.";
      loginError.hidden = false;
    }
  });

  logoutButton.addEventListener("click", async function () {
    try { await api("/api/logout", { method: "POST" }); } catch (e) {}
    onUnauthorized();
  });

  // ───────────────────────── List ──────────────────────────
  async function openList() {
    showView("list");
    await loadNotes(searchInput.value || "");
  }

  async function loadNotes(q) {
    try {
      var path = "/api/notes" + (q ? "?q=" + encodeURIComponent(q) : "");
      notes = await api(path);
    } catch (e) { return; }
    renderNotes();
  }

  function renderNotes() {
    notesList.innerHTML = "";
    var isEmpty = notes.length === 0;
    emptyState.hidden = !isEmpty;
    notesList.hidden = isEmpty;
    notes.forEach(function (n) { notesList.appendChild(renderRow(n)); });
    notesCount.textContent = countLabel(notes.length);
  }

  function renderRow(n) {
    var row = document.createElement("button");
    row.className = "note-row";
    row.setAttribute("role", "listitem");

    var primary = (n.title || "").trim();
    var secondary = (n.snippet || "").trim();
    if (!primary) { primary = secondary || "New Note"; secondary = ""; }

    var titleEl = document.createElement("div");
    titleEl.className = "row-title";
    titleEl.dir = "auto";
    if (n.pinned) {
      var pin = document.createElement("span");
      pin.className = "pin-mark";
      pin.textContent = "📌";
      titleEl.appendChild(pin);
    }
    var t = document.createElement("span");
    t.textContent = primary;
    titleEl.appendChild(t);

    var sub = document.createElement("div");
    sub.className = "row-sub";
    sub.dir = "auto";
    var date = document.createElement("span");
    date.className = "row-date";
    date.textContent = formatDate(n.updated_at);
    var snip = document.createElement("span");
    snip.className = "row-snippet";
    snip.textContent = secondary || "No additional text";
    sub.appendChild(date);
    sub.appendChild(snip);

    row.appendChild(titleEl);
    row.appendChild(sub);
    row.addEventListener("click", function () { openExisting(n.id); });
    return row;
  }

  function countLabel(n) {
    if (n === 0) return "No Notes";
    if (n === 1) return "1 Note";
    return n + " Notes";
  }

  searchInput.addEventListener("input", function () {
    clearTimeout(searchTimer);
    var q = searchInput.value;
    searchTimer = setTimeout(function () { loadNotes(q); }, 220);
  });

  composeButton.addEventListener("click", function () { openDraft(); });

  // ───────────────────────── Editor ────────────────────────
  function fillEditor() {
    titleInput.value = current.title || "";
    bodyInput.value = current.content || "";
    editorDate.textContent = formatFullDate(current.updated_at);
    updatePinUI();
  }

  function openDraft() {
    var nowIso = new Date().toISOString();
    current = { id: null, title: "", content: "", pinned: false, created_at: nowIso, updated_at: nowIso };
    isDraft = true;
    createPromise = null;
    fillEditor();
    showView("editor");
    bodyInput.focus(); // synchronous within the tap gesture → keyboard appears on iOS
  }

  async function openExisting(id) {
    try { current = await api("/api/notes/" + id); } catch (e) { return; }
    isDraft = false;
    createPromise = null;
    fillEditor();
    showView("editor");
  }

  function syncInputs() {
    if (!current) return;
    current.title = titleInput.value;
    current.content = bodyInput.value;
  }

  function scheduleSave() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(function () { saveNote(); }, 700);
  }

  titleInput.addEventListener("input", function () { syncInputs(); scheduleSave(); });
  bodyInput.addEventListener("input", function () { syncInputs(); scheduleSave(); });

  async function saveNote() {
    clearTimeout(saveTimer);
    if (!current) return;
    var title = titleInput.value;
    var content = bodyInput.value;

    if (isDraft) {
      if (!title.trim() && !content.trim()) return;
      if (!createPromise) {
        createPromise = api("/api/notes", {
          method: "POST",
          body: JSON.stringify({ title: title, content: content }),
        })
          .then(function (created) { current = created; isDraft = false; })
          .catch(function () { toast("Couldn’t save note"); })
          .finally(function () { createPromise = null; });
      }
      await createPromise;
      return;
    }

    if (current.id) {
      try {
        current = await api("/api/notes/" + current.id, {
          method: "PUT",
          body: JSON.stringify({ title: title, content: content }),
        });
      } catch (e) { toast("Couldn’t save note"); }
    }
  }

  async function goBack() {
    clearTimeout(saveTimer);
    var title = titleInput.value.trim();
    var content = bodyInput.value.trim();

    if (isDraft && !title && !content) {
      // empty draft — discard silently
    } else if (!isDraft && current && current.id && !title && !content) {
      try { await api("/api/notes/" + current.id, { method: "DELETE" }); } catch (e) {}
    } else {
      await saveNote();
    }
    current = null;
    isDraft = false;
    await openList();
  }

  backButton.addEventListener("click", function () { goBack(); });

  deleteButton.addEventListener("click", async function () {
    if (isDraft && !titleInput.value.trim() && !bodyInput.value.trim()) {
      current = null; isDraft = false; return openList();
    }
    if (!window.confirm("Delete this note?")) return;
    clearTimeout(saveTimer);
    if (current && current.id) {
      try { await api("/api/notes/" + current.id, { method: "DELETE" }); }
      catch (e) { toast("Couldn’t delete note"); return; }
    }
    current = null; isDraft = false; openList();
  });

  pinButton.addEventListener("click", async function () {
    if (isDraft) {
      await saveNote();
      if (isDraft) { toast("Write something first, then pin it"); return; }
    }
    if (!current || !current.id) return;
    var next = !current.pinned;
    try {
      current = await api("/api/notes/" + current.id, {
        method: "PUT",
        body: JSON.stringify({ pinned: next }),
      });
      updatePinUI();
      toast(next ? "Pinned to top" : "Unpinned");
    } catch (e) { toast("Couldn’t update note"); }
  });

  function updatePinUI() {
    pinButton.classList.toggle("active", !!(current && current.pinned));
  }

  // ─────────────────────── Recording ───────────────────────
  var recording = false;
  var audioCtx = null, mediaStream = null, processor = null, sourceNode = null, zeroGain = null;
  var chunks = [], recordedLen = 0, inputSampleRate = 44100;
  var recIntervalId = null, recStartMs = 0, bodyCursor = null;

  micButton.addEventListener("click", function () {
    if (recording) stopRecording();
    else startRecording();
  });
  recStatus.addEventListener("click", function () { if (recording) stopRecording(); });

  async function startRecording() {
    if (!config.transcription_configured) {
      toast("Voice-to-text isn’t set up yet. Add your OpenRouter API key to .env.");
      return;
    }
    if (!window.isSecureContext || !navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      toast("Microphone needs a secure (https) connection. See the README for HTTPS / Tailscale setup.");
      return;
    }

    bodyCursor = document.activeElement === bodyInput ? bodyInput.selectionStart : null;

    try {
      mediaStream = await navigator.mediaDevices.getUserMedia({
        audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true },
      });
    } catch (e) {
      toast("Microphone permission was denied.");
      return;
    }

    try {
      var AC = window.AudioContext || window.webkitAudioContext;
      audioCtx = new AC();
      if (audioCtx.state === "suspended") { try { await audioCtx.resume(); } catch (e) {} }
      inputSampleRate = audioCtx.sampleRate;
      sourceNode = audioCtx.createMediaStreamSource(mediaStream);
      processor = audioCtx.createScriptProcessor(4096, 1, 1);
      zeroGain = audioCtx.createGain();
      zeroGain.gain.value = 0; // silence local monitoring (no feedback)
      chunks = [];
      recordedLen = 0;
      processor.onaudioprocess = function (e) {
        var input = e.inputBuffer.getChannelData(0);
        chunks.push(new Float32Array(input));
        recordedLen += input.length;
      };
      sourceNode.connect(processor);
      processor.connect(zeroGain);
      zeroGain.connect(audioCtx.destination);
    } catch (e) {
      cleanupAudio();
      toast("Couldn’t start recording on this device.");
      return;
    }

    recording = true;
    micButton.classList.add("recording");
    showRecStatus("recording");
    recStartMs = Date.now();
    updateRecTimer();
    recIntervalId = setInterval(updateRecTimer, 500);
  }

  function updateRecTimer() {
    var s = Math.floor((Date.now() - recStartMs) / 1000);
    recTimer.textContent = Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");
  }

  function cleanupAudio() {
    try { if (processor) { processor.disconnect(); processor.onaudioprocess = null; } } catch (e) {}
    try { if (sourceNode) sourceNode.disconnect(); } catch (e) {}
    try { if (zeroGain) zeroGain.disconnect(); } catch (e) {}
    try { if (mediaStream) mediaStream.getTracks().forEach(function (t) { t.stop(); }); } catch (e) {}
    try { if (audioCtx) audioCtx.close(); } catch (e) {}
    processor = sourceNode = zeroGain = mediaStream = audioCtx = null;
  }

  async function stopRecording() {
    if (!recording) return;
    recording = false;
    clearInterval(recIntervalId);
    micButton.classList.remove("recording");

    var rate = inputSampleRate;
    var merged = mergeBuffers(chunks, recordedLen);
    chunks = [];
    cleanupAudio();

    if (!merged.length) { hideRecStatus(); toast("No audio was captured."); return; }
    if (merged.length < rate * 0.3) { hideRecStatus(); toast("That was too short — hold on a moment longer."); return; }

    var targetRate = Math.min(16000, rate);
    var down = targetRate === rate ? merged : downsample(merged, rate, targetRate);
    var wav = encodeWAV(down, targetRate);

    showRecStatus("transcribing");
    micButton.classList.add("busy");
    try {
      var form = new FormData();
      form.append("audio", wav, "note.wav");
      var res = await fetch("/api/transcribe", { method: "POST", credentials: "same-origin", body: form });
      if (res.status === 401) { onUnauthorized(); throw new Error("unauthorized"); }
      if (!res.ok) {
        var d = "Transcription failed";
        try { d = (await res.json()).detail || d; } catch (e) {}
        throw new Error(d);
      }
      var data = await res.json();
      var text = (data.text || "").trim();
      if (!text) toast("No speech was detected.");
      else insertText(text);
    } catch (e) {
      if (e.message !== "unauthorized") toast(e.message || "Transcription failed");
    } finally {
      micButton.classList.remove("busy");
      hideRecStatus();
    }
  }

  function insertText(text) {
    var el = bodyInput;
    var pos = bodyCursor != null ? bodyCursor : el.value.length;
    var before = el.value.slice(0, pos);
    var after = el.value.slice(pos);
    var insert = text;
    if (before && !/\s$/.test(before)) insert = " " + insert;
    el.value = before + insert + after;
    var newPos = (before + insert).length;
    try { el.setSelectionRange(newPos, newPos); } catch (e) {}
    bodyCursor = newPos;
    syncInputs();
    saveNote();
  }

  function showRecStatus(mode) {
    recStatus.hidden = false;
    recStatus.classList.toggle("transcribing", mode === "transcribing");
    recText.textContent = mode === "transcribing" ? "Transcribing…" : "Recording… tap to stop";
  }
  function hideRecStatus() {
    recStatus.hidden = true;
    recStatus.classList.remove("transcribing");
  }

  // ───────────── Audio helpers (Float32 → 16-bit WAV) ───────────
  function mergeBuffers(bufferList, totalLen) {
    var result = new Float32Array(totalLen);
    var offset = 0;
    for (var i = 0; i < bufferList.length; i++) {
      result.set(bufferList[i], offset);
      offset += bufferList[i].length;
    }
    return result;
  }

  function downsample(buffer, inRate, outRate) {
    if (outRate >= inRate) return buffer;
    var ratio = inRate / outRate;
    var newLen = Math.round(buffer.length / ratio);
    var result = new Float32Array(newLen);
    var offsetResult = 0, offsetBuffer = 0;
    while (offsetResult < newLen) {
      var nextOffset = Math.round((offsetResult + 1) * ratio);
      var sum = 0, count = 0;
      for (var i = offsetBuffer; i < nextOffset && i < buffer.length; i++) { sum += buffer[i]; count++; }
      result[offsetResult] = count > 0 ? sum / count : 0;
      offsetResult++;
      offsetBuffer = nextOffset;
    }
    return result;
  }

  function encodeWAV(samples, sampleRate) {
    var buffer = new ArrayBuffer(44 + samples.length * 2);
    var view = new DataView(buffer);
    function writeString(offset, str) {
      for (var i = 0; i < str.length; i++) view.setUint8(offset + i, str.charCodeAt(i));
    }
    writeString(0, "RIFF");
    view.setUint32(4, 36 + samples.length * 2, true);
    writeString(8, "WAVE");
    writeString(12, "fmt ");
    view.setUint32(16, 16, true);        // Subchunk1Size (PCM)
    view.setUint16(20, 1, true);         // AudioFormat = PCM
    view.setUint16(22, 1, true);         // Channels = mono
    view.setUint32(24, sampleRate, true);
    view.setUint32(28, sampleRate * 2, true); // ByteRate
    view.setUint16(32, 2, true);         // BlockAlign
    view.setUint16(34, 16, true);        // BitsPerSample
    writeString(36, "data");
    view.setUint32(40, samples.length * 2, true);
    var offset = 44;
    for (var i = 0; i < samples.length; i++, offset += 2) {
      var s = Math.max(-1, Math.min(1, samples[i]));
      view.setInt16(offset, s < 0 ? s * 0x8000 : s * 0x7fff, true);
    }
    return new Blob([view], { type: "audio/wav" });
  }

  // ───────────────────────── Dates ─────────────────────────
  function formatDate(iso) {
    var d = new Date(iso);
    if (isNaN(d.getTime())) return "";
    var now = new Date();
    if (d.toDateString() === now.toDateString()) {
      return d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
    }
    var diffDays = Math.floor((now - d) / 86400000);
    if (diffDays >= 0 && diffDays < 7) {
      return d.toLocaleDateString([], { weekday: "long" });
    }
    var sameYear = d.getFullYear() === now.getFullYear();
    return d.toLocaleDateString([], sameYear
      ? { month: "short", day: "numeric" }
      : { year: "numeric", month: "short", day: "numeric" });
  }

  function formatFullDate(iso) {
    var d = new Date(iso);
    if (isNaN(d.getTime())) return "";
    return (
      d.toLocaleDateString([], { day: "numeric", month: "long", year: "numeric" }) +
      "  ·  " +
      d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
    );
  }

  // ───────────────────────── Toast ─────────────────────────
  var toastTimer = null;
  function toast(msg) {
    toastEl.textContent = msg;
    toastEl.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toastEl.hidden = true; }, 3400);
  }

  // ───────────────────────── Service worker ────────────────
  function registerServiceWorker() {
    if ("serviceWorker" in navigator) {
      navigator.serviceWorker.register("/sw.js").catch(function () {});
    }
  }

  // ───────────────────────── Init ──────────────────────────
  async function init() {
    try { config = await api("/api/config"); } catch (e) {}
    applyConfig();
    if (config.auth_required && !config.authenticated) {
      showView("login");
      setTimeout(function () { loginPassword && loginPassword.focus(); }, 120);
    } else {
      await openList();
    }
    registerServiceWorker();
  }

  init();
})();
