let lastTime = 0;
let isPaused = false;

let canvasOpacity = 0.8;
let canvasFontScale = 1.0;
let canvasNicoMode = 'default';
let strokeColor = '#000000';
let strokeInversionColor = '#ffffff';
let strokeOpacity = 0.4;
let strokeWidth = 2.8;
let commentLimit = 0;
let scrollSpeed = 1.0;
let danmakuTimeOffsetSec = 0;
let danmakuFontFamily = "";
let danmakuFontWeight = "";
let fixedComboEnabled = false; // 固定弹幕渐进合并(= main 的去重开关)
let blockEnabled = false;      // 屏蔽词开关
let blockWords = [];           // 已转小写的屏蔽词
let dedupeEnabled = false;     // 弹幕去重（同文合并 + 滚动窗口去重）
let blockExact = false;        // 屏蔽词匹配方式：false 包含 / true 整条相等
let repeatFilter = false;      // 纯重复弹幕（啊啊啊 / 哈哈哈 / www）
let nakaDedupeWindow = 0; // 滚动弹幕窗口去重(1/100s,0=关;= main 的去重窗口×100)

let niconiComments = null;
let nicoRawData = null;
let rawFormattedData = null; // 未注入滚动速度命令的原始 formatted 数据
let rawNicoJsonData = null; // 未注入滚动速度的原始 nico-json JSON 文本
let nicoRawFormat = 'legacy';
let canvasRafId = null;
let canvasVideoAnchorTime = 0;
let canvasSystemAnchorTime = 0;
let canvasIsPlaying = false;
let playbackSpeed = 1.0;
let danmakuVisible = true;

function canvasSyncAnchor(videoTimeSec) {
  canvasVideoAnchorTime = videoTimeSec;
  canvasSystemAnchorTime = performance.now();
}

function canvasGetCurrentTime() {
  const baseTime = !canvasIsPlaying ? canvasVideoAnchorTime : canvasVideoAnchorTime + ((performance.now() - canvasSystemAnchorTime) / 1000) * playbackSpeed;
  return baseTime + danmakuTimeOffsetSec;
}

// "词1, 词2 词3、词4" → ['词1','词2','词3','词4']（大小写不敏感，去空去重）
function parseBlockWords(raw) {
  if (!raw) return [];
  const out = [];
  const seen = {};
  String(raw).split(/[,，、;；\s]+/).forEach(function (w) {
    const t = w.trim().toLowerCase();
    if (!t || seen[t]) return;
    seen[t] = 1;
    out.push(t);
  });
  return out;
}

// 整条只是同一个字反复（啊啊 / 啊啊啊 / 哈哈哈哈哈 / wwwww / ？？？ / 233333）
// 先去掉空白和首尾标点，再看是不是「全同一个字符」或「末尾一长串相同字符」
function isPureRepeat(text) {
  let t = String(text || '').replace(/\s+/g, '');
  if (!t) return false;
  const core = t.replace(/^[\p{P}\p{S}]+|[\p{P}\p{S}]+$/gu, '');
  t = core || t;                       // 整条都是标点（？？？ / ……）就用原串比
  if (t.length < 2) return false;

  let same = true;
  for (let i = 1; i < t.length; i++) {
    if (t[i] !== t[0]) { same = false; break; }
  }
  if (same) return true;               // 啊啊、啊啊啊、wwww

  // 「2 + 一长串 3」这种：末尾连续 ≥3 个相同字符，前面最多 2 个字符
  let j = t.length - 1;
  while (j > 0 && t[j] === t[t.length - 1]) j--;
  const runLen = t.length - 1 - j;
  return (runLen >= 3 && j <= 1);
}

// 过滤只作用在喂给渲染器的那份数据上（nicoRawData 保留全量，改设置还能恢复）
function applyBlockFilter(data) {
  if (!Array.isArray(data)) return data;
  const useBlock = blockEnabled && blockWords.length > 0;
  if (!useBlock && !repeatFilter) return data;
  return data.filter(function (c) {
    const raw = String((c && (c.content !== undefined ? c.content : c.text)) || '');
    if (repeatFilter && isPureRepeat(raw)) return false;
    if (!useBlock) return true;
    const t = raw.toLowerCase();
    for (let i = 0; i < blockWords.length; i++) {
      const w = blockWords[i];
      if (blockExact ? (t.trim() === w) : (t.indexOf(w) !== -1)) return false;
    }
    return true;
  });
}

function detectNicoFormat(data) {
  if (Array.isArray(data) && data.length > 0) {
    if (data[0].comments !== undefined && Array.isArray(data[0].comments)) return 'v1';
    if (data[0].chat !== undefined) return 'legacy';
  }
  return 'legacy';
}

function toNumericUserId(userId, userMap) {
  const numeric = Number(userId);
  if (!isNaN(numeric) && isFinite(numeric)) return numeric;
  const key = String(userId || '');
  if (userMap[key] === undefined) {
    userMap._nextId = (userMap._nextId || 0) + 1;
    userMap[key] = userMap._nextId;
  }
  return userMap[key];
}

function buildFormattedCanvasData(list, sourceType) {
  const userMap = {};
  const result = [];
  for (let i = 0; i < list.length; i++) {
    const d = list[i];
    result.push({
      id: i,
      no: d._no || 0,
      vpos: Math.round(d.t || 0),
      content: d.text || '',
      date: d._dateSec || 0,
      date_usec: 0,
      owner: sourceType !== 'bilibili-xml' && !!d._isOwner,
      premium: true,
      mail: Array.isArray(d._commands) ? d._commands : [],
      user_id: toNumericUserId(d._userId, userMap),
      layer: -1,
      is_my_post: false
    });
  }
  return result;
}

function prepareCanvasSource(rawStr, parsedList, sourceType) {
  nicoRawData = null;
  rawFormattedData = null;
  rawNicoJsonData = null;
  if (sourceType === 'nico-json') {
    try {
      nicoRawData = JSON.parse(rawStr);
      rawNicoJsonData = rawStr;
      nicoRawFormat = detectNicoFormat(nicoRawData);
      applyScrollSpeedToNicoJson(nicoRawData);
      return;
    } catch (e) {
      console.warn('niconicomments JSON parse failed, using formatted data:', e);
    }
  }
  rawFormattedData = buildFormattedCanvasData(parsedList, sourceType);
  applyScrollSpeed();
  nicoRawFormat = 'formatted';
}

// nico-json (v1/legacy 线程数组) 的滚动速度注入:
// v1: thread.comments[].commands 数组; legacy: thread.chat[].mail 字符串
function applyScrollSpeedToNicoJson(data) {
  if (!Array.isArray(data)) return;
  var k = scrollSpeed;
  if (!isFinite(k) || k <= 0) k = 1;
  if (k >= 1) return; // 100% = 原生速度,不做任何处理
  var longSecs = Math.max(0.5, 4 / k - 1);
  for (var i = 0; i < data.length; i++) {
    var thread = data[i];
    if (!thread) continue;
    if (thread.fork === 'owner') continue; // owner 弹幕(投稿者弹幕)不注入,保持默认速度
    var comments = Array.isArray(thread.comments) ? thread.comments : (Array.isArray(thread.chat) ? thread.chat : null);
    if (!comments) continue;
    for (var j = 0; j < comments.length; j++) {
      var c = comments[j];
      if (!c) continue;
      var cmds = Array.isArray(c.commands) ? c.commands : (typeof c.mail === 'string' ? c.mail.split(/\s+/).filter(Boolean) : null);
      if (!cmds) continue;
      if (cmds.indexOf('ue') !== -1 || cmds.indexOf('shita') !== -1) continue; // 固定弹幕不注入
      if (cmds.some(function (m) { return /^[@＠][0-9.]/.test(m); })) continue; // 自带时长命令不动
      cmds.push('@' + longSecs);
      if (typeof c.mail === 'string') c.mail = cmds.join(' '); // legacy 字符串同步回写
    }
  }
}

// 滚动弹幕速度倍率: 引擎 speed = (画布宽 + 弹幕宽×offset) / (long + 100)
// long 在分母 → 通过给 naka 弹幕注入 @秒数 命令(nicoscript 显示时长)实现真实速度倍率。
// 默认 long=300 (3s): 目标倍率 k → long = 400/k - 100 (vpos) = 4/k - 1 (秒)
function applyScrollSpeed() {
  if (!rawFormattedData) {
    nicoRawData = null;
    return;
  }
  var k = scrollSpeed;
  if (!isFinite(k) || k <= 0) k = 1;
  if (k >= 1) { // 100% = 原生速度,不做任何处理
    nicoRawData = rawFormattedData;
    return;
  }
  var longSecs = Math.max(0.5, 4 / k - 1);
  nicoRawData = rawFormattedData.map(function (c) {
    var mail = c.mail;
    if (!Array.isArray(mail)) return c;
    // 滚动弹幕判定: 显式 naka, 或没有 ue/shita 位置命令(本地 nico XML 的默认弹幕 mail 为空)
    var isScroll = mail.indexOf('naka') !== -1 || (mail.indexOf('ue') === -1 && mail.indexOf('shita') === -1);
    if (!isScroll) return c;
    if (mail.some(function (m) { return /^[@＠][0-9.]/.test(m); })) return c; // 自带时长命令的不动
    return Object.assign({}, c, { mail: mail.concat(['@' + longSecs]) });
  });
}

const canvasEventHandlers = {
  seekDisable: () => iina.postMessage("seek-disable", {}),
  seekEnable: () => iina.postMessage("seek-enable", {}),
  jump: (e) => {
    if (e.targetVpos !== null && e.targetVpos !== undefined) {
      iina.postMessage("jump", { targetSec: e.targetVpos / 100, message: e.message, to: e.to });
    } else if (e.to) {
      iina.postMessage("jump-video", { videoId: e.to, message: e.message });
    }
  }
};

function bindCanvasEvents(instance) {
  instance.addEventListener("seekDisable", canvasEventHandlers.seekDisable);
  instance.addEventListener("seekEnable", canvasEventHandlers.seekEnable);
  instance.addEventListener("jump", canvasEventHandlers.jump);
}

function unbindCanvasEvents(instance) {
  if (!instance || typeof instance.removeEventListener !== 'function') return;
  instance.removeEventListener("seekDisable", canvasEventHandlers.seekDisable);
  instance.removeEventListener("seekEnable", canvasEventHandlers.seekEnable);
  instance.removeEventListener("jump", canvasEventHandlers.jump);
}

function disposeCanvasRenderer() {
  if (!niconiComments) return;
  unbindCanvasEvents(niconiComments);
  niconiComments.clear();
  niconiComments.destroy();
  niconiComments = null;
}

var DEFAULT_DANMAKU_FONT_STACKS = {
  gothic: { font: '"游ゴシック体", "游ゴシック", "Yu Gothic", YuGothic, yugothic, YuGo-Medium, "Hiragino Sans", HiraginoSans', offset: -0.04, weight: 400 },
  mincho: { font: '"游明朝体", "游明朝", "Yu Mincho", YuMincho, yumincho, YuMin-Medium, "Hiragino Mincho ProN", HiraMinProN, "Hiragino Mincho ProN W3", HiraMinProN-W3', offset: -0.01, weight: 400 },
  defont: { font: '"Hiragino Sans", "ヒラギノ角ゴシック", HiraginoSans', offset: -0.05, weight: 600 },
};

function buildDanmakuFontConfig() {
  var weight = danmakuFontWeight ? parseInt(danmakuFontWeight, 10) : 400;
  if (isNaN(weight) || weight < 100 || weight > 900) weight = 400;
  var mk = function (type) {
    var def = DEFAULT_DANMAKU_FONT_STACKS[type];
    return {
      font: danmakuFontFamily || def.font,
      offset: danmakuFontFamily ? 0 : def.offset,
      weight: weight,
    };
  };
  return {
    flash: {
      gulim: 'normal 600 [size]px gulim, ' + (danmakuFontFamily || DEFAULT_DANMAKU_FONT_STACKS.gothic.font) + ', Arial',
      simsun: 'normal 400 [size]px simsun, batang, "PMingLiU", MingLiU-ExtB, ' + (danmakuFontFamily || DEFAULT_DANMAKU_FONT_STACKS.mincho.font) + ', Arial',
    },
    html5: {
      gothic: mk('gothic'),
      mincho: mk('mincho'),
      defont: mk('defont'),
    },
  };
}

function initCanvasRenderer(data) {
  // 兜底：反复重建渲染器时 canvas 有可能被移除，直接补一个回来，
  // 否则 initCanvasRenderer 会静默 return，弹幕就再也画不出来了
  let canvas = document.getElementById('niconicomments-canvas');
  if (!canvas) {
    canvas = document.createElement('canvas');
    canvas.id = 'niconicomments-canvas';
    document.body.appendChild(canvas);
  }
  if (!canvas || typeof NiconiComments === 'undefined') return;
  // 画布像素比例必须跟容器一模一样：CSS 是 object-fit: contain，
  // 比例不一致就会在框内留边、弹幕缩成中间一条。
  // 宽度锁 1920（字号按宽度换算，保证跟以前一致），高度按容器比例算 ——
  // 「显示区域」把容器变矮时，这里跟着变矮，能放的行数自然变少，字号不变。
  canvas.width = 1920;
  const boxW = Math.max(1, Math.round(window.innerWidth || 1920));
  const boxH = Math.max(1, Math.round(window.innerHeight || 1080));
  canvas.height = Math.max(80, Math.round(1920 * boxH / boxW));
  canvas.style.height = '100%';
  const useCssMode = canvasNicoMode === 'css';
  canvas.style.opacity = useCssMode ? 0 : canvasOpacity;
  disposeCanvasRenderer();
  // 过滤只作用在这一次渲染上，nicoRawData 仍保留全量，
  // 这样把屏蔽词删掉/关掉以后还能把弹幕找回来
  const renderData = applyBlockFilter(data);
  niconiComments = new NiconiComments(canvas, renderData, {
    format: nicoRawFormat,
    mode: canvasNicoMode,
    keepCA: true,
    scale: canvasFontScale,
    config: {
      // 库内部按 canvasWidth/Height 与画布实际尺寸的比例做缩放；
      // 不写的话默认 1920x1080，容器变矮时纵向会被压成一条
      canvasWidth: canvas.width,
      canvasHeight: canvas.height,
      contextStrokeColor: strokeColor,
      contextStrokeInversionColor: strokeInversionColor,
      contextStrokeOpacity: strokeOpacity,
      contextLineWidth: { html5: strokeWidth, flash: strokeWidth },
      commentLimit: commentLimit > 0 ? commentLimit : undefined,
      fonts: buildDanmakuFontConfig(),
      fixedCombo: fixedComboEnabled,
      nakaDedupeWindow: nakaDedupeWindow,
    },
  });
  nicoRawData = data;
  // 初始化时同步当前播放速度(CSS 模式滚动动画时长按倍率缩放)
  if (niconiComments && niconiComments.setPlaybackSpeed) {
    niconiComments.setPlaybackSpeed(playbackSpeed);
  }
  bindCanvasEvents(niconiComments);
  drawCanvasAtVpos(canvasGetCurrentTime() * 100, true);
  if (isPaused && useCssMode) {
    niconiComments.pauseCSS();
  }
  if (useCssMode) {
    const cssContainer = document.querySelector('[data-dm-css-container]');
    if (cssContainer) cssContainer.style.opacity = canvasOpacity;
  }
  // 弹幕关闭状态下重建渲染器(改字体/描边等)时,renderer 会新建容器,
  // 需恢复隐藏状态,否则弹幕会重新出现。
  if (!danmakuVisible) {
    const canvasEl = document.getElementById('niconicomments-canvas');
    if (canvasEl) canvasEl.style.display = 'none';
    const cssContainer = document.querySelector('[data-dm-css-container]');
    if (cssContainer) cssContainer.style.display = 'none';
    stopCanvasLoop();
    if (niconiComments) niconiComments.clear();
  }
}

function shouldRunCanvasLoop() {
  return !!(niconiComments && danmakuVisible && canvasIsPlaying);
}

function drawCanvasAtVpos(vpos, forceRendering) {
  if (!niconiComments) return;
  const renderVpos = canvasNicoMode === 'css' ? Math.floor(vpos) : vpos;
  niconiComments.drawCanvas(renderVpos, !!forceRendering);
}

function canvasRenderLoop() {
  canvasRafId = null;
  if (!shouldRunCanvasLoop()) return;
  drawCanvasAtVpos(canvasGetCurrentTime() * 100, false);
  startCanvasLoop();
}

function startCanvasLoop() {
  if (canvasRafId || !shouldRunCanvasLoop()) return;
  canvasRafId = requestAnimationFrame(canvasRenderLoop);
}

function stopCanvasLoop() {
  if (canvasRafId !== null) {
    cancelAnimationFrame(canvasRafId);
    canvasRafId = null;
  }
}

function applyOpacityToDom() {
  const canvas = document.getElementById('niconicomments-canvas');
  if (canvas && canvasNicoMode !== 'css') canvas.style.opacity = canvasOpacity;
  const cssContainer = document.querySelector('[data-dm-css-container]');
  if (cssContainer) cssContainer.style.opacity = canvasOpacity;
}

// load-danmaku 共用的逐字段幂等设置应用(重复携带无副作用)
function applyOverlaySettings(data) {
  if (data.opacity !== undefined) { canvasOpacity = data.opacity; applyOpacityToDom(); }
  if (data.canvasFontScale !== undefined) canvasFontScale = data.canvasFontScale;
  if (data.canvasMode !== undefined) canvasNicoMode = data.canvasMode;
  if (data.strokeColor !== undefined) strokeColor = data.strokeColor;
  if (data.strokeInversionColor !== undefined) strokeInversionColor = data.strokeInversionColor;
  if (data.strokeOpacity !== undefined) strokeOpacity = data.strokeOpacity;
  if (data.strokeWidth !== undefined) strokeWidth = data.strokeWidth;
  if (data.commentLimit !== undefined) commentLimit = data.commentLimit;
  if (data.scrollSpeed !== undefined) scrollSpeed = data.scrollSpeed;
  if (data.danmakuTimeOffsetSec !== undefined) danmakuTimeOffsetSec = Number(data.danmakuTimeOffsetSec) || 0;
  if (data.danmakuFontFamily !== undefined) danmakuFontFamily = data.danmakuFontFamily || "";
  if (data.danmakuFontWeight !== undefined) danmakuFontWeight = data.danmakuFontWeight || "";
  if (data.fixedCombo !== undefined) fixedComboEnabled = !!data.fixedCombo;
  if (data.nakaDedupeWindow !== undefined) nakaDedupeWindow = Number(data.nakaDedupeWindow) || 0;
  if (data.danmakuBlockEnabled !== undefined) blockEnabled = !!data.danmakuBlockEnabled;
  if (data.danmakuBlockWords !== undefined) blockWords = parseBlockWords(data.danmakuBlockWords);
  if (data.danmakuBlockExact !== undefined) blockExact = !!data.danmakuBlockExact;
  if (data.danmakuFilterRepeat !== undefined) repeatFilter = !!data.danmakuFilterRepeat;
  if (data.danmakuDedupe !== undefined) {
    dedupeEnabled = !!data.danmakuDedupe;
    fixedComboEnabled = dedupeEnabled;
    nakaDedupeWindow = dedupeEnabled ? 300 : 0;
  }
}

iina.onMessage("time-update", (data) => {
  let t = data.time * 100;
  const isSeek = Math.abs(t - lastTime) > 150;
  if (isSeek) stopCanvasLoop();
  canvasSyncAnchor(data.time);
  lastTime = t;
  if (isSeek && niconiComments) {
    niconiComments.clear();
    // 必须用偏移后时间: 裸视频时间会在负偏移时把本该延后的弹幕提前生成,
    // CSS 模式弹幕是 DOM 动画,生成后会完整飘完一遍再出现第二次(重复)
    drawCanvasAtVpos(canvasGetCurrentTime() * 100, true);
  }
  startCanvasLoop();
});

iina.onMessage("load-danmaku", (data) => {
  applyOverlaySettings(data);

  const encodedStr = data.xmlContent;
  let rawStr;
  try { rawStr = decodeURIComponent(encodedStr); } catch (e) {
    console.log('[overlay] decodeURIComponent failed: ' + e);
    return;
  }

  var danmakuType = data.danmakuType;

  let parsedList;
  if (danmakuType === 'dandanplay') {
    try {
      parsedList = JSON.parse(rawStr);
    } catch (e) {
      console.log('[overlay] parse dandanplay failed: ' + e);
      parsedList = [];
    }
  } else if (danmakuType === 'nico-json') {
    parsedList = [];
  } else {
    parsedList = parseDanmaku(rawStr, true);
  }

  prepareCanvasSource(rawStr, parsedList, danmakuType);

  iina.postMessage("danmaku-type", { type: danmakuType });

  if (nicoRawData) {
    canvasIsPlaying = !isPaused;
    initCanvasRenderer(nicoRawData);
    startCanvasLoop();
  }
});

let metricsTimer = null;
function scheduleMetricsRefresh() {
  if (metricsTimer) clearTimeout(metricsTimer);
  metricsTimer = setTimeout(() => {
    metricsTimer = null;
    if (nicoRawData) {
      initCanvasRenderer(nicoRawData);
      startCanvasLoop();
    } else if (niconiComments) {
      niconiComments.clear();
      drawCanvasAtVpos(canvasGetCurrentTime() * 100, true);
    }
  }, 120);
}

iina.onMessage("resize", () => scheduleMetricsRefresh());

iina.onMessage("pause-state", (data) => {
  // canvasGetCurrentTime() 返回的是含偏移的时间,而锚点存的是裸视频时间——
  // 回写前必须剥离偏移,否则下次读取会二次叠加偏移
  const anchoredTime = canvasGetCurrentTime() - danmakuTimeOffsetSec;
  isPaused = !!data.paused;
  canvasIsPlaying = !isPaused;
  canvasSyncAnchor(anchoredTime);
  if (niconiComments) {
    if (isPaused) {
      stopCanvasLoop();
      niconiComments.pauseCSS();
    } else {
      niconiComments.resumeCSS();
      startCanvasLoop();
    }
  }
});

iina.onMessage("playback-speed", (data) => {
  const anchoredTime = canvasGetCurrentTime() - danmakuTimeOffsetSec;
  playbackSpeed = data && data.speed ? data.speed : 1.0;
  canvasSyncAnchor(anchoredTime);
  // 通知 CSS 渲染器:速度变化时重设滚动动画时长(1x 无操作)
  if (niconiComments && niconiComments.setPlaybackSpeed) {
    niconiComments.setPlaybackSpeed(playbackSpeed);
  }
});

iina.onMessage("toggle-danmaku", (data) => {
  danmakuVisible = !!data.enabled;
  const canvas = document.getElementById('niconicomments-canvas');
  if (canvas) canvas.style.display = data.enabled ? '' : 'none';
  const cssContainer = document.querySelector('[data-dm-css-container]');
  if (cssContainer) cssContainer.style.display = data.enabled ? '' : 'none';
  if (!data.enabled) {
    stopCanvasLoop();
    if (niconiComments) niconiComments.clear();
  } else {
    startCanvasLoop();
    // 暂停中重开: rAF loop 不会启动(shouldRunCanvasLoop 要求正在播放),
    // 且关闭分支已 clear() 清空内容——必须强制重绘一次,否则画面空白直到恢复播放
    drawCanvasAtVpos(canvasGetCurrentTime() * 100, true);
  }
});

iina.onMessage("set-opacity", (data) => {
  canvasOpacity = data.opacity;
  applyOpacityToDom();
});

iina.onMessage("set-fontscale", (data) => {
  canvasFontScale = data.scale;
  if (nicoRawData) initCanvasRenderer(nicoRawData);
});

iina.onMessage("set-canvas-mode", (data) => {
  const oldMode = canvasNicoMode;
  canvasNicoMode = data.mode;
  if (nicoRawData) {
    initCanvasRenderer(nicoRawData);
    startCanvasLoop();
    if (oldMode === 'css' && canvasNicoMode !== 'css') {
      const cssContainer = document.querySelector('[data-dm-css-container]');
      if (cssContainer) cssContainer.remove();
    }
  }
});

iina.onMessage("set-stroke-opacity", (data) => {
  strokeOpacity = data.opacity;
  if (nicoRawData) initCanvasRenderer(nicoRawData);
});

iina.onMessage("set-stroke-width", (data) => {
  strokeWidth = data.width;
  if (nicoRawData) initCanvasRenderer(nicoRawData);
});

iina.onMessage("set-stroke-color", (data) => {
  strokeColor = data.color;
  if (nicoRawData) initCanvasRenderer(nicoRawData);
});

iina.onMessage("set-stroke-inversion-color", (data) => {
  strokeInversionColor = data.color;
  if (nicoRawData) initCanvasRenderer(nicoRawData);
});

iina.onMessage("set-comment-limit", (data) => {
  commentLimit = data.limit;
  if (nicoRawData) initCanvasRenderer(nicoRawData);
});

iina.onMessage("set-scroll-speed", (data) => {
  scrollSpeed = data.speed;
  if (rawFormattedData) {
    applyScrollSpeed();
    initCanvasRenderer(nicoRawData);
  } else if (rawNicoJsonData) {
    nicoRawData = JSON.parse(rawNicoJsonData);
    applyScrollSpeedToNicoJson(nicoRawData);
    initCanvasRenderer(nicoRawData);
  }
});

iina.onMessage("set-danmaku-offset", (data) => {
  if (data.offset !== undefined) {
    danmakuTimeOffsetSec = Number(data.offset) || 0;
  }
  if (nicoRawData && niconiComments) {
    // 偏移变化等同于时间轴跳转。CSSRenderer 使用增量 DOM，
    // 必须先清空，否则旧时间点的弹幕会与新时间点的弹幕叠加。
    niconiComments.clear();
    drawCanvasAtVpos(canvasGetCurrentTime() * 100, true);
  }
});

iina.onMessage("set-danmaku-filter", (data) => {
  const nextWords = parseBlockWords(data && data.words);
  const nextBlock = !!(data && data.block);
  const nextDedupe = !!(data && data.dedupe);
  const nextExact = !!(data && data.exact);
  const nextRepeat = !!(data && data.repeat);
  const wordsChanged = nextWords.join('\u0001') !== blockWords.join('\u0001');
  const changed = nextBlock !== blockEnabled || nextDedupe !== dedupeEnabled ||
                  nextExact !== blockExact || nextRepeat !== repeatFilter || wordsChanged;
  blockEnabled = nextBlock;
  blockWords = nextWords;
  blockExact = nextExact;
  repeatFilter = nextRepeat;
  dedupeEnabled = nextDedupe;
  fixedComboEnabled = nextDedupe;
  nakaDedupeWindow = nextDedupe ? 300 : 0;
  if (changed && nicoRawData) {
    initCanvasRenderer(nicoRawData);
    startCanvasLoop();
  }
});

iina.onMessage("set-danmaku-font", (data) => {
  if (data.fontFamily !== undefined) danmakuFontFamily = data.fontFamily || "";
  if (data.fontWeight !== undefined) danmakuFontWeight = data.fontWeight || "";
  if (nicoRawData) initCanvasRenderer(nicoRawData);
});

iina.onMessage("clear-danmaku", () => {
  stopCanvasLoop();
  disposeCanvasRenderer();
  lastTime = 0;
  canvasVideoAnchorTime = 0;
  canvasSystemAnchorTime = 0;
  canvasIsPlaying = false;
  const cssContainer = document.querySelector('[data-dm-css-container]');
  if (cssContainer) cssContainer.remove();
  nicoRawData = null;
  rawFormattedData = null;
  rawNicoJsonData = null;
  nicoRawFormat = 'legacy';
  iina.postMessage("danmaku-type", { type: 'none' });
});

// overlay 自身的 file:// 根目录(插件启动即加载,上报给 main 用于读 opencc.min.js
// ——不依赖侧栏懒加载,简繁转换器在重启后打开新视频时即可构建)
function overlayPluginRoot() {
  try {
    var u = new URL('../', window.location.href);
    var p = decodeURIComponent(u.pathname);
    if (p.length > 1 && p.charAt(p.length - 1) === '/') p = p.slice(0, -1);
    return p;
  } catch (e) {
    return '';
  }
}

iina.postMessage("overlay-ready", { pluginRoot: overlayPluginRoot() });
