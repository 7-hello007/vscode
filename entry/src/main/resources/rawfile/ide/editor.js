(function () {
  'use strict';

  const workspace = document.getElementById('workspace');
  const editor = document.getElementById('editor');
  const highlight = document.getElementById('highlight');
  const gutterContent = document.getElementById('gutterContent');
  const findBar = document.getElementById('findBar');
  const findInput = document.getElementById('findInput');
  const replaceInput = document.getElementById('replaceInput');
  const findResult = document.getElementById('findResult');
  const statusMessage = document.getElementById('statusMessage');
  const cursorPosition = document.getElementById('cursorPosition');
  const languageLabel = document.getElementById('languageLabel');
  const foldNotice = document.getElementById('foldNotice');

  let filePath = '';
  let language = 'plaintext';
  let lastSelectionContext = '';
  let fullContent = '';
  let encoding = 'UTF-8';
  let lineEnding = 'LF';
  let folds = [];
  let history = [];
  let historyIndex = -1;
  let historyTimer = 0;
  let findMatches = [];
  let findMatchIndex = -1;

  const languageNames = {
    javascript: 'JavaScript', typescript: 'TypeScript', python: 'Python', shell: 'Shell',
    json: 'JSON', html: 'HTML', css: 'CSS', c: 'C/C++', java: 'Java', kotlin: 'Kotlin',
    rust: 'Rust', go: 'Go', markdown: 'Markdown', yaml: 'YAML', xml: 'XML', plaintext: 'Plain Text'
  };

  const keywords = {
    javascript: new Set('as async await break case catch class const continue debugger default delete do else export extends false finally for from function get if import in instanceof let new null of return set static super switch this throw true try typeof undefined var void while with yield'.split(' ')),
    typescript: new Set('abstract any as async await boolean break case catch class const constructor continue declare default delete do else enum export extends false finally for from function get if implements import in infer instanceof interface keyof let namespace never new null number object of private protected public readonly return set static string super switch symbol this throw true try type typeof undefined unknown var void while with yield'.split(' ')),
    python: new Set('and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield'.split(' ')),
    shell: new Set('case do done elif else esac export fi for function if in local readonly return then until while'.split(' ')),
    c: new Set('auto bool break case char class const constexpr continue default delete do double else enum explicit extern false float for friend if inline int long namespace new nullptr operator private protected public register return short signed sizeof static struct switch template this throw true try typedef typename union unsigned using virtual void volatile while'.split(' ')),
    java: new Set('abstract assert boolean break byte case catch char class const continue default do double else enum extends false final finally float for goto if implements import instanceof int interface long native new null package private protected public return short static strictfp super switch synchronized this throw throws transient true try void volatile while'.split(' ')),
    kotlin: new Set('as break class continue do else false for fun if in interface is null object package return super this throw true try typealias typeof val var when while'.split(' ')),
    rust: new Set('as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while'.split(' ')),
    go: new Set('break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var'.split(' '))
  };

  function invokeNative(method) {
    try {
      const bridge = window.editorBridge;
      if (!bridge || typeof bridge[method] !== 'function') return;
      const args = Array.prototype.slice.call(arguments, 1);
      bridge[method].apply(bridge, args);
    } catch (error) {
      statusMessage.textContent = 'Native bridge unavailable';
    }
  }

  function toBase64(value) {
    const bytes = new TextEncoder().encode(value);
    let binary = '';
    const chunkSize = 8192;
    for (let offset = 0; offset < bytes.length; offset += chunkSize) {
      const chunk = bytes.subarray(offset, Math.min(offset + chunkSize, bytes.length));
      binary += String.fromCharCode.apply(null, chunk);
    }
    return btoa(binary);
  }

  function fromBase64(value) {
    if (!value) return '';
    const binary = atob(value);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
    return new TextDecoder('utf-8').decode(bytes);
  }

  function languageForPath(path) {
    const extension = path.indexOf('.') === -1 ? '' : path.substring(path.lastIndexOf('.') + 1).toLowerCase();
    const map = {
      js: 'javascript', jsx: 'javascript', mjs: 'javascript', cjs: 'javascript',
      ts: 'typescript', tsx: 'typescript', py: 'python', pyw: 'python',
      sh: 'shell', bash: 'shell', zsh: 'shell', json: 'json', json5: 'json',
      html: 'html', htm: 'html', css: 'css', scss: 'css', less: 'css',
      c: 'c', h: 'c', cc: 'c', cpp: 'c', cxx: 'c', hpp: 'c',
      java: 'java', kt: 'kotlin', kts: 'kotlin', rs: 'rust', go: 'go',
      md: 'markdown', markdown: 'markdown', yaml: 'yaml', yml: 'yaml', xml: 'xml'
    };
    return map[extension] || 'plaintext';
  }

  function escapeHtml(value) {
    return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  function highlightMarkup(source) {
    const pattern = /<!--[\s\S]*?-->|<\/?[A-Za-z][^>]*>/g;
    let output = '';
    let cursor = 0;
    let match;
    while ((match = pattern.exec(source)) !== null) {
      output += escapeHtml(source.substring(cursor, match.index));
      const token = match[0];
      output += '<span class="' + (token.startsWith('<!--') ? 'tok-comment' : 'tok-tag') + '">' +
        escapeHtml(token) + '</span>';
      cursor = match.index + token.length;
    }
    return output + escapeHtml(source.substring(cursor));
  }

  function highlightMarkdown(source) {
    return source.split('\n').map(function (line) {
      if (/^\s{0,3}#{1,6}\s/.test(line)) return '<span class="tok-heading">' + escapeHtml(line) + '</span>';
      if (/^\s*(```|~~~)/.test(line)) return '<span class="tok-keyword">' + escapeHtml(line) + '</span>';
      return escapeHtml(line).replace(/(`[^`]+`)/g, '<span class="tok-string">$1</span>');
    }).join('\n');
  }

  function highlightGeneric(source, currentLanguage) {
    const hashComments = currentLanguage === 'python' || currentLanguage === 'shell' || currentLanguage === 'yaml';
    const pattern = /\/\*[\s\S]*?\*\/|\/\/[^\n]*|#[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|\b(?:0x[\da-fA-F]+|\d+(?:\.\d+)?)\b|\b[A-Za-z_$][\w$]*\b/g;
    const keywordSet = keywords[currentLanguage] || new Set();
    let output = '';
    let cursor = 0;
    let match;
    while ((match = pattern.exec(source)) !== null) {
      output += escapeHtml(source.substring(cursor, match.index));
      const token = match[0];
      let tokenClass = '';
      if (token.startsWith('/*') || token.startsWith('//') || (hashComments && token.startsWith('#'))) {
        tokenClass = 'tok-comment';
      } else if (token[0] === '"' || token[0] === '\'' || token[0] === '`') {
        tokenClass = 'tok-string';
      } else if (/^(?:0x[\da-fA-F]+|\d)/.test(token)) {
        tokenClass = 'tok-number';
      } else if (keywordSet.has(token) || (currentLanguage === 'json' && /^(true|false|null)$/.test(token))) {
        tokenClass = 'tok-keyword';
      } else if (/^[A-Z]/.test(token)) {
        tokenClass = 'tok-type';
      } else {
        const afterToken = source.substring(match.index + token.length);
        if (/^\s*\(/.test(afterToken)) tokenClass = 'tok-function';
      }
      output += tokenClass ? '<span class="' + tokenClass + '">' + escapeHtml(token) + '</span>' : escapeHtml(token);
      cursor = match.index + token.length;
    }
    return output + escapeHtml(source.substring(cursor));
  }

  function highlightCode(source) {
    if (language === 'html' || language === 'xml') return highlightMarkup(source);
    if (language === 'markdown') return highlightMarkdown(source);
    if (language === 'plaintext') return escapeHtml(source);
    return highlightGeneric(source, language);
  }

  function leadingSpaces(line) {
    const match = line.match(/^[\t ]*/);
    if (!match) return 0;
    return match[0].replace(/\t/g, '  ').length;
  }

  function braceFoldRange(lines, start) {
    const first = lines[start];
    const opening = (first.match(/[\{\[]/g) || []).length;
    const closing = (first.match(/[\}\]]/g) || []).length;
    if (opening <= closing) return null;
    let depth = opening - closing;
    for (let index = start + 1; index < lines.length; index++) {
      depth += (lines[index].match(/[\{\[]/g) || []).length;
      depth -= (lines[index].match(/[\}\]]/g) || []).length;
      if (depth <= 0) return index > start + 1 ? { start: start, end: index } : null;
    }
    return null;
  }

  function indentationFoldRange(lines, start) {
    if (!/:\s*(?:#.*)?$/.test(lines[start])) return null;
    const baseIndent = leadingSpaces(lines[start]);
    let last = start;
    for (let index = start + 1; index < lines.length; index++) {
      if (!lines[index].trim()) continue;
      if (leadingSpaces(lines[index]) <= baseIndent) break;
      last = index;
    }
    return last > start + 1 ? { start: start, end: last } : null;
  }

  function markupFoldRange(lines, start) {
    const match = lines[start].match(/<([A-Za-z][\w:-]*)\b[^>]*>(?!.*<\/\1>)/);
    if (!match || /\/\s*>/.test(match[0])) return null;
    const close = new RegExp('<\\/' + match[1] + '\\s*>', 'i');
    for (let index = start + 1; index < lines.length; index++) {
      if (close.test(lines[index])) return index > start + 1 ? { start: start, end: index } : null;
    }
    return null;
  }

  function foldRangeAt(lines, start) {
    if (language === 'python' || language === 'yaml') return indentationFoldRange(lines, start);
    if (language === 'html' || language === 'xml') return markupFoldRange(lines, start);
    return braceFoldRange(lines, start);
  }

  function displayRows() {
    const lines = fullContent.split('\n');
    const rows = [];
    const foldMap = new Map();
    folds.forEach(function (fold) { foldMap.set(fold.start, fold); });
    for (let sourceLine = 0; sourceLine < lines.length; sourceLine++) {
      const fold = foldMap.get(sourceLine);
      if (fold) {
        rows.push({ sourceLine: sourceLine, text: lines[sourceLine] + '  ⋯', folded: true, foldable: true });
        sourceLine = fold.end;
      } else {
        rows.push({
          sourceLine: sourceLine,
          text: lines[sourceLine],
          folded: false,
          foldable: foldRangeAt(lines, sourceLine) !== null
        });
      }
    }
    return rows;
  }

  function renderGutter(rows) {
    gutterContent.innerHTML = rows.map(function (row) {
      const toggle = row.foldable ? '<button class="fold-toggle" data-line="' + row.sourceLine + '">' +
        (row.folded ? '▶' : '▼') + '</button>' : '<span></span>';
      return '<div class="gutter-line">' + toggle + '<span class="line-number" data-number="' +
        (row.sourceLine + 1) + '">' + (row.sourceLine + 1) + '</span></div>';
    }).join('');
    gutterContent.querySelectorAll('.fold-toggle').forEach(function (button) {
      button.addEventListener('click', function () { toggleFold(parseInt(button.dataset.line, 10)); });
    });
  }

  function render(setEditorValue) {
    if (!filePath) return;
    const rows = displayRows();
    const visibleContent = rows.map(function (row) { return row.text; }).join('\n');
    if (setEditorValue) editor.value = visibleContent;
    highlight.innerHTML = highlightCode(visibleContent) + '\n';
    renderGutter(rows);
    editor.readOnly = folds.length > 0;
    foldNotice.classList.toggle('hidden', folds.length === 0);
    syncScroll();
    updateCursor();
  }

  function toggleFold(sourceLine) {
    const existing = folds.findIndex(function (fold) { return fold.start === sourceLine; });
    if (existing !== -1) {
      folds.splice(existing, 1);
    } else {
      const range = foldRangeAt(fullContent.split('\n'), sourceLine);
      if (range) folds.push(range);
    }
    folds.sort(function (left, right) { return left.start - right.start; });
    render(true);
  }

  function foldAll() {
    const lines = fullContent.split('\n');
    const ranges = [];
    let lastEnd = -1;
    for (let line = 0; line < lines.length; line++) {
      if (line <= lastEnd) continue;
      const range = foldRangeAt(lines, line);
      if (range) {
        ranges.push(range);
        lastEnd = range.end;
      }
    }
    folds = ranges;
    render(true);
  }

  function unfoldAll(restoreFocus) {
    if (folds.length === 0) return;
    folds = [];
    render(true);
    if (restoreFocus) editor.focus();
  }

  function syncScroll() {
    highlight.style.transform = 'translate(' + (-editor.scrollLeft) + 'px,' + (-editor.scrollTop) + 'px)';
    gutterContent.style.transform = 'translateY(' + (-editor.scrollTop) + 'px)';
  }

  function resetHistory(content) {
    window.clearTimeout(historyTimer);
    history = [content];
    historyIndex = 0;
  }

  function commitHistory() {
    window.clearTimeout(historyTimer);
    if (history[historyIndex] === fullContent) return;
    history = history.slice(0, historyIndex + 1);
    history.push(fullContent);
    if (history.length > 200) history.shift();
    historyIndex = history.length - 1;
  }

  function scheduleHistory() {
    window.clearTimeout(historyTimer);
    historyTimer = window.setTimeout(commitHistory, 250);
  }

  function applyHistory(index) {
    if (index < 0 || index >= history.length) return;
    historyIndex = index;
    fullContent = history[index];
    folds = [];
    editor.value = fullContent;
    render(false);
    notifyContentChanged();
  }

  function undo() {
    commitHistory();
    if (historyIndex > 0) applyHistory(historyIndex - 1);
  }

  function redo() {
    commitHistory();
    if (historyIndex < history.length - 1) applyHistory(historyIndex + 1);
  }

  function notifyContentChanged() {
    if (!filePath) return;
    invokeNative('onEditorContentChanged', toBase64(filePath), toBase64(fullContent));
  }

  function requestSave() {
    if (!filePath) return;
    commitHistory();
    statusMessage.textContent = 'Saving...';
    invokeNative('onEditorSaveRequested', toBase64(filePath), toBase64(fullContent));
  }

  function updateCursor() {
    const before = editor.value.substring(0, editor.selectionStart);
    const line = before.split('\n').length;
    const lastBreak = before.lastIndexOf('\n');
    const column = editor.selectionStart - lastBreak;
    cursorPosition.textContent = 'Ln ' + line + ', Col ' + column;
    invokeNative('onEditorStatusChanged', line, column, toBase64(encoding), toBase64(lineEnding));
    gutterContent.querySelectorAll('.line-number').forEach(function (element) {
      element.classList.toggle('active', parseInt(element.dataset.number, 10) === line);
    });
    notifySelectionContext();
  }

  function notifySelectionContext() {
    const selected = editor.value.substring(editor.selectionStart, editor.selectionEnd);
    const signature = selected + '\u0000' + language;
    if (signature === lastSelectionContext) return;
    lastSelectionContext = signature;
    invokeNative('onEditorSelectionChanged', toBase64(selected), toBase64(language));
  }

  function openFind(showReplace) {
    unfoldAll(false);
    findBar.classList.remove('hidden');
    workspace.classList.remove('find-closed');
    replaceInput.style.display = showReplace ? '' : 'none';
    document.getElementById('replaceButton').style.display = showReplace ? '' : 'none';
    document.getElementById('replaceAllButton').style.display = showReplace ? '' : 'none';
    const selected = editor.value.substring(editor.selectionStart, editor.selectionEnd);
    if (selected && selected.indexOf('\n') === -1) findInput.value = selected;
    refreshFindMatches();
    findInput.focus();
    findInput.select();
  }

  function closeFind() {
    findBar.classList.add('hidden');
    editor.focus();
  }

  function refreshFindMatches() {
    findMatches = [];
    findMatchIndex = -1;
    const query = findInput.value;
    if (!query) {
      findResult.textContent = '0/0';
      return;
    }
    let offset = 0;
    while (offset <= fullContent.length - query.length) {
      const found = fullContent.indexOf(query, offset);
      if (found === -1) break;
      findMatches.push(found);
      offset = found + Math.max(1, query.length);
    }
    findResult.textContent = '0/' + findMatches.length;
  }

  function findNext(direction) {
    unfoldAll(false);
    refreshFindMatches();
    if (findMatches.length === 0) return;
    const current = editor.selectionStart;
    if (direction > 0) {
      findMatchIndex = findMatches.findIndex(function (position) { return position > current; });
      if (findMatchIndex === -1) findMatchIndex = 0;
    } else {
      findMatchIndex = -1;
      for (let index = findMatches.length - 1; index >= 0; index--) {
        if (findMatches[index] < current) { findMatchIndex = index; break; }
      }
      if (findMatchIndex === -1) findMatchIndex = findMatches.length - 1;
    }
    const start = findMatches[findMatchIndex];
    editor.focus();
    editor.setSelectionRange(start, start + findInput.value.length);
    findResult.textContent = (findMatchIndex + 1) + '/' + findMatches.length;
    updateCursor();
  }

  function replaceCurrent() {
    unfoldAll(false);
    const query = findInput.value;
    if (!query) return;
    if (editor.value.substring(editor.selectionStart, editor.selectionEnd) !== query) {
      findNext(1);
      return;
    }
    const start = editor.selectionStart;
    const replacement = replaceInput.value;
    fullContent = editor.value.substring(0, start) + replacement + editor.value.substring(editor.selectionEnd);
    editor.value = fullContent;
    editor.setSelectionRange(start, start + replacement.length);
    commitHistory();
    render(false);
    notifyContentChanged();
    refreshFindMatches();
  }

  function replaceAll() {
    unfoldAll(false);
    const query = findInput.value;
    if (!query) return;
    const count = fullContent.split(query).length - 1;
    if (count === 0) return;
    fullContent = fullContent.split(query).join(replaceInput.value);
    editor.value = fullContent;
    commitHistory();
    render(false);
    notifyContentChanged();
    refreshFindMatches();
    statusMessage.textContent = 'Replaced ' + count + ' matches';
  }

  function setDocument(pathBase64, contentBase64) {
    filePath = fromBase64(pathBase64);
    fullContent = fromBase64(contentBase64);
    encoding = 'UTF-8';
    lineEnding = fullContent.indexOf('\r\n') !== -1 ? 'CRLF' : 'LF';
    language = languageForPath(filePath);
    folds = [];
    editor.value = fullContent;
    editor.scrollTop = 0;
    editor.scrollLeft = 0;
    editor.readOnly = false;
    workspace.classList.remove('empty');
    languageLabel.textContent = languageNames[language] || language;
    statusMessage.textContent = 'Ready';
    resetHistory(fullContent);
    lastSelectionContext = '';
    render(false);
    notifySelectionContext();
    editor.focus();
    updateCursor();
  }

  function clearDocument() {
    filePath = '';
    fullContent = '';
    encoding = 'UTF-8';
    lineEnding = 'LF';
    folds = [];
    editor.value = '';
    highlight.textContent = '';
    gutterContent.textContent = '';
    workspace.classList.add('empty');
    languageLabel.textContent = 'Plain Text';
    statusMessage.textContent = 'Ready';
    resetHistory('');
    lastSelectionContext = '';
    notifySelectionContext();
    updateCursor();
  }

  window.hishEditor = {
    setDocumentBase64: setDocument,
    clearDocument: clearDocument,
    requestSave: requestSave,
    setSavedBase64: function (pathBase64) {
      if (fromBase64(pathBase64) === filePath) statusMessage.textContent = 'Saved';
    },
    setErrorBase64: function (messageBase64) { statusMessage.textContent = fromBase64(messageBase64); },
    focus: function () { editor.focus(); },
    undo: undo,
    redo: redo,
    openFind: function () { openFind(false); },
    openReplace: function () { openFind(true); },
    selectAll: function () {
      editor.focus();
      editor.setSelectionRange(0, editor.value.length);
      updateCursor();
    },
    goStart: function () {
      editor.focus();
      editor.setSelectionRange(0, 0);
      updateCursor();
    },
    goEnd: function () {
      editor.focus();
      editor.setSelectionRange(editor.value.length, editor.value.length);
      updateCursor();
    }
  };

  editor.addEventListener('input', function () {
    if (folds.length > 0) return;
    fullContent = editor.value;
    lineEnding = fullContent.indexOf('\r\n') !== -1 ? 'CRLF' : 'LF';
    highlight.innerHTML = highlightCode(fullContent) + '\n';
    renderGutter(displayRows());
    scheduleHistory();
    notifyContentChanged();
    syncScroll();
    updateCursor();
  });
  editor.addEventListener('scroll', syncScroll);
  editor.addEventListener('click', updateCursor);
  editor.addEventListener('keyup', updateCursor);
  editor.addEventListener('keydown', function (event) {
    const control = event.ctrlKey || event.metaKey;
    if (control && event.key.toLowerCase() === 's') {
      event.preventDefault();
      requestSave();
    } else if (event.key === 'F5' || (control && event.key === 'Enter')) {
      event.preventDefault();
      invokeNative('onEditorRunRequested');
    } else if (control && event.key.toLowerCase() === 'f') {
      event.preventDefault();
      openFind(false);
    } else if (control && event.key.toLowerCase() === 'h') {
      event.preventDefault();
      openFind(true);
    } else if (control && event.key.toLowerCase() === 'z' && !event.shiftKey) {
      event.preventDefault();
      undo();
    } else if ((control && event.key.toLowerCase() === 'y') ||
      (control && event.shiftKey && event.key.toLowerCase() === 'z')) {
      event.preventDefault();
      redo();
    } else if (event.key === 'Tab' && folds.length === 0) {
      event.preventDefault();
      const start = editor.selectionStart;
      const end = editor.selectionEnd;
      editor.setRangeText('  ', start, end, 'end');
      editor.dispatchEvent(new Event('input'));
    }
  });

  document.getElementById('undoButton').addEventListener('click', undo);
  document.getElementById('redoButton').addEventListener('click', redo);
  document.getElementById('findButton').addEventListener('click', function () { openFind(false); });
  document.getElementById('foldButton').addEventListener('click', foldAll);
  document.getElementById('unfoldButton').addEventListener('click', function () { unfoldAll(true); });
  document.getElementById('previousButton').addEventListener('click', function () { findNext(-1); });
  document.getElementById('nextButton').addEventListener('click', function () { findNext(1); });
  document.getElementById('replaceButton').addEventListener('click', replaceCurrent);
  document.getElementById('replaceAllButton').addEventListener('click', replaceAll);
  document.getElementById('closeFindButton').addEventListener('click', closeFind);
  findInput.addEventListener('input', refreshFindMatches);
  findInput.addEventListener('keydown', function (event) {
    if (event.key === 'Enter') { event.preventDefault(); findNext(event.shiftKey ? -1 : 1); }
    if (event.key === 'Escape') closeFind();
  });
  replaceInput.addEventListener('keydown', function (event) {
    if (event.key === 'Enter') { event.preventDefault(); replaceCurrent(); }
    if (event.key === 'Escape') closeFind();
  });
  foldNotice.addEventListener('click', function () { unfoldAll(true); });

  resetHistory('');
  window.setTimeout(function () { invokeNative('onEditorReady'); }, 0);
})();
