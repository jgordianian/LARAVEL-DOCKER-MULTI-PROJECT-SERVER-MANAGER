(() => {
  const root = document.querySelector('.chat-main');
  if (!root) return;

  const csrf = root.dataset.csrf;
  const messages = document.getElementById('messages');
  const composer = document.getElementById('composer');
  const prompt = document.getElementById('prompt');
  const model = document.getElementById('model-select');
  const reasoning = document.getElementById('reasoning-select');
  const reasoningSaveState = document.getElementById('reasoning-save-state');
  const stop = document.getElementById('stop');
  const send = document.getElementById('send');
  const rename = document.getElementById('rename-chat');
  const remove = document.getElementById('delete-chat');
  const imagePicker = document.getElementById('image-picker');
  const imageInput = document.getElementById('image-input');
  const imagePreview = document.getElementById('image-preview');
  const imageStatus = document.getElementById('image-status');
  let conversationId = null;
  let aborter = null;
  let savedReasoning = reasoning.dataset.savedValue || reasoning.value;
  let pendingImages = [];
  let editingMessageId = null;
  let imageStatusError = '';
  const MAX_IMAGES = 10;
  const MAX_IMAGE_BYTES = 20 * 1024 * 1024;
  const MAX_TOTAL_IMAGE_BYTES = 60 * 1024 * 1024;
  const translate = value => window.aiTranslate ? window.aiTranslate(value) : value;
  const clearEditing = () => {
    editingMessageId = null;
    send.textContent = translate('Send');
  };

  const modelSupportsReasoning = () => model.selectedOptions[0]?.dataset.reasoning === 'true';
  const modelSupportsVision = () => model.selectedOptions[0]?.dataset.vision === 'true';
  const effectiveReasoning = () => modelSupportsReasoning() ? reasoning.value : 'none';
  const syncReasoningAvailability = () => {
    reasoning.disabled = !modelSupportsReasoning();
    reasoning.title = reasoning.disabled ? 'The selected model is not configured for reasoning.' : '';
  };
  const renderPendingImages = () => {
    imagePreview.innerHTML = '';
    imagePreview.hidden = pendingImages.length === 0;
    pendingImages.forEach((attachment, index) => {
      const item = document.createElement('div');
      item.className = 'image-preview-item';
      const preview = document.createElement('img');
      preview.src = attachment.data_url;
      preview.alt = attachment.name;
      const name = document.createElement('span');
      name.textContent = attachment.name;
      const removeImage = document.createElement('button');
      removeImage.type = 'button';
      removeImage.className = 'image-remove';
      removeImage.setAttribute('aria-label', 'Remove image');
      removeImage.title = 'Remove image';
      removeImage.textContent = '×';
      removeImage.addEventListener('click', () => {
        pendingImages.splice(index, 1);
        imageStatusError = '';
        renderPendingImages();
        syncImageAvailability();
      });
      item.append(preview, name, removeImage);
      imagePreview.appendChild(item);
    });
  };
  const clearPendingImages = () => {
    pendingImages = [];
    imageStatusError = '';
    imageInput.value = '';
    renderPendingImages();
  };
  const syncImageAvailability = () => {
    const supported = modelSupportsVision();
    imagePicker.disabled = !supported || Boolean(aborter);
    imagePicker.title = supported ? 'Attach images' : 'The selected model does not support image inputs.';
    if (!supported && pendingImages.length) clearPendingImages();
    imageStatus.textContent = !supported
      ? 'The selected model does not support image inputs.'
      : imageStatusError
        ? imageStatusError
        : (pendingImages.length ? `${pendingImages.length} of ${MAX_IMAGES} images ready` : 'Up to 10 images · PNG, JPEG or WebP · 20 MB each · 60 MB total');
  };

  const escapeHtml = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const highlight = value => value.replace(/\b(const|let|var|function|class|def|return|if|else|for|while|async|await|import|from|try|catch|except|true|false|null|None)\b/g, '<span class="syntax-keyword">$1</span>');
  const inlineMarkdown = value => {
    const codeFragments = [];
    let safe = escapeHtml(value).replace(/`([^`\n]+)`/g, (_, code) => {
      const token = `\u0000CODE${codeFragments.length}\u0000`;
      codeFragments.push(`<code>${code}</code>`);
      return token;
    });
    safe = safe.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
    safe = safe.replace(/__([^_\n]+)__/g, '<strong>$1</strong>');
    safe = safe.replace(/(^|[\s(])\*([^*\n]+)\*(?=$|[\s).,!?:;])/g, '$1<em>$2</em>');
    safe = safe.replace(/(^|[\s(])_([^_\n]+)_(?=$|[\s).,!?:;])/g, '$1<em>$2</em>');
    codeFragments.forEach((fragment, index) => {
      safe = safe.replace(`\u0000CODE${index}\u0000`, fragment);
    });
    return safe;
  };
  const markdown = value => {
    const lines = String(value).replace(/\r\n?/g, '\n').split('\n');
    const output = [];
    let paragraph = [];
    let listType = '';
    let inFence = false;
    let fenceLanguage = '';
    let fenceLines = [];

    const closeParagraph = () => {
      if (!paragraph.length) return;
      output.push(`<p>${paragraph.map(inlineMarkdown).join('<br>')}</p>`);
      paragraph = [];
    };
    const closeList = () => {
      if (!listType) return;
      output.push(`</${listType}>`);
      listType = '';
    };
    const openList = type => {
      closeParagraph();
      if (listType === type) return;
      closeList();
      listType = type;
      output.push(`<${type}>`);
    };
    const closeFence = () => {
      const language = escapeHtml(fenceLanguage);
      const code = highlight(escapeHtml(fenceLines.join('\n')));
      output.push(`<pre><button type="button" class="copy-code">Copy</button><code data-lang="${language}">${code}</code></pre>`);
      inFence = false;
      fenceLanguage = '';
      fenceLines = [];
    };

    for (const line of lines) {
      const fence = line.match(/^\s*```([\w-]*)\s*$/);
      if (fence) {
        if (inFence) closeFence();
        else {
          closeParagraph();
          closeList();
          inFence = true;
          fenceLanguage = fence[1] || '';
        }
        continue;
      }
      if (inFence) {
        fenceLines.push(line);
        continue;
      }
      if (!line.trim()) {
        closeParagraph();
        closeList();
        continue;
      }
      const heading = line.match(/^\s{0,3}(#{1,6})\s+(.+)$/);
      if (heading) {
        closeParagraph();
        closeList();
        const level = heading[1].length;
        output.push(`<h${level}>${inlineMarkdown(heading[2])}</h${level}>`);
        continue;
      }
      const unordered = line.match(/^\s*[-+*]\s+(.+)$/);
      if (unordered) {
        openList('ul');
        output.push(`<li>${inlineMarkdown(unordered[1])}</li>`);
        continue;
      }
      const ordered = line.match(/^\s*\d+[.)]\s+(.+)$/);
      if (ordered) {
        openList('ol');
        output.push(`<li>${inlineMarkdown(ordered[1])}</li>`);
        continue;
      }
      const quote = line.match(/^\s*>\s?(.*)$/);
      if (quote) {
        closeParagraph();
        closeList();
        output.push(`<blockquote>${inlineMarkdown(quote[1])}</blockquote>`);
        continue;
      }
      closeList();
      paragraph.push(line.trim());
    }
    closeParagraph();
    closeList();
    if (inFence) closeFence();
    return output.join('');
  };
  const wireCopyButtons = container => {
    container.querySelectorAll('.copy-code').forEach(button => button.addEventListener('click', async () => {
      await navigator.clipboard.writeText(button.nextElementSibling.textContent);
      button.textContent = 'Copied';
      setTimeout(() => { button.textContent = 'Copy'; }, 1200);
    }));
  };
  const renderContent = (container, content) => {
    container.innerHTML = markdown(content);
    wireCopyButtons(container);
  };
  const showThinking = output => {
    output.row.classList.add('is-thinking');
    const indicator = document.createElement('div');
    indicator.className = 'thinking-indicator';
    indicator.setAttribute('role', 'status');
    indicator.setAttribute('aria-live', 'polite');
    const label = document.createElement('span');
    label.className = 'thinking-label';
    label.textContent = translate('AI is thinking');
    const dots = document.createElement('span');
    dots.className = 'thinking-dots';
    dots.setAttribute('aria-hidden', 'true');
    dots.append(document.createElement('span'), document.createElement('span'), document.createElement('span'));
    indicator.append(label, dots);
    output.target.replaceChildren(indicator);
  };
  const clearThinking = output => {
    if (!output.row.classList.contains('is-thinking')) return;
    output.row.classList.remove('is-thinking');
    output.target.replaceChildren();
  };
  const addAssistantActions = (actions, row) => {
    if (actions.childElementCount) return;
    const copy = document.createElement('button');
    copy.type = 'button'; copy.textContent = 'Copy';
    copy.addEventListener('click', () => navigator.clipboard.writeText(row.dataset.content));
    const regenerate = document.createElement('button');
    regenerate.type = 'button'; regenerate.textContent = 'Regenerate';
    regenerate.addEventListener('click', () => generate('', true));
    actions.append(copy, regenerate);
  };
  const addUserActions = (actions, row) => {
    if (actions.childElementCount || !row.dataset.messageId) return;
    const edit = document.createElement('button');
    edit.type = 'button'; edit.textContent = 'Edit & resend';
    edit.addEventListener('click', () => {
      if (aborter) return;
      editingMessageId = Number(row.dataset.messageId);
      prompt.value = row.dataset.content;
      prompt.dispatchEvent(new Event('input'));
      send.textContent = translate('Resend');
      prompt.focus();
    });
    actions.appendChild(edit);
  };
  const renderAttachments = (container, attachments) => {
    if (!attachments?.length) return;
    const gallery = document.createElement('div');
    gallery.className = 'message-images';
    attachments.forEach(attachment => {
      const link = document.createElement('a');
      const source = attachment.url || attachment.data_url;
      link.href = source;
      link.target = '_blank';
      link.rel = 'noopener';
      const preview = document.createElement('img');
      preview.src = source;
      preview.alt = attachment.name || 'Attached image';
      preview.loading = 'lazy';
      link.appendChild(preview);
      gallery.appendChild(link);
    });
    container.appendChild(gallery);
  };
  const bubble = (role, content = '', createdAt = null, final = true, attachments = [], messageId = null) => {
    messages.querySelector('.empty')?.remove();
    const row = document.createElement('div');
    row.className = `message ${role}`;
    row.dataset.content = content;
    if (messageId) row.dataset.messageId = messageId;
    row.innerHTML = `<div class="avatar">${role === 'assistant' ? 'AI' : 'YOU'}</div><div><div class="message-content"></div><div class="message-meta"><time></time><span class="message-actions"></span></div></div>`;
    const target = row.querySelector('.message-content');
    renderContent(target, content);
    renderAttachments(target, attachments);
    row.querySelector('time').textContent = createdAt ? new Date(createdAt).toLocaleString() : new Date().toLocaleTimeString();
    const actions = row.querySelector('.message-actions');
    if (role === 'user') {
      addUserActions(actions, row);
    } else if (final) {
      addAssistantActions(actions, row);
    }
    messages.appendChild(row);
    messages.scrollTop = messages.scrollHeight;
    return {target, row, actions};
  };
  const emptyState = () => {
    clearEditing();
    messages.innerHTML = '<div class="empty"><div class="mark">AI</div><h1>How can I help?</h1><p>Choose an active permitted model and start a private conversation.</p></div>';
    document.getElementById('chat-title').textContent = 'New conversation';
    rename.hidden = true; remove.hidden = true;
  };
  const refreshConversationList = async () => {
    const response = await fetch('/api/conversations');
    if (!response.ok) return;
    const list = document.getElementById('conversation-list');
    list.innerHTML = '';
    for (const item of await response.json()) {
      const button = document.createElement('button');
      button.className = 'conversation';
      button.dataset.id = item.id;
      button.innerHTML = `<span>${escapeHtml(item.title)}</span><small>${escapeHtml(item.model)}</small>`;
      button.addEventListener('click', () => loadConversation(item.id));
      list.appendChild(button);
    }
  };
  const createConversation = async () => {
    const response = await fetch('/api/conversations', {
      method: 'POST', headers: {'Content-Type':'application/json'},
      body: JSON.stringify({model:model.value, csrf_token:csrf})
    });
    if (!response.ok) throw new Error((await response.json()).detail || 'Unable to create conversation');
    const data = await response.json();
    conversationId = data.id;
    history.replaceState({}, '', `/?conversation=${conversationId}`);
    rename.hidden = false; remove.hidden = false;
    await refreshConversationList();
    return data;
  };
  const loadConversation = async id => {
    const response = await fetch(`/api/conversations/${id}`);
    if (!response.ok) return;
    const data = await response.json();
    clearEditing();
    conversationId = data.id;
    model.value = data.model;
    syncReasoningAvailability();
    clearPendingImages();
    syncImageAvailability();
    document.getElementById('chat-title').textContent = data.title;
    rename.hidden = false; remove.hidden = false;
    messages.innerHTML = '';
    data.messages.forEach(item => bubble(item.role, item.content, item.created_at, true, item.attachments, item.id));
    document.querySelectorAll('.conversation').forEach(button => button.classList.toggle('active', Number(button.dataset.id) === data.id));
    history.replaceState({}, '', `/?conversation=${conversationId}`);
  };
  const generate = async (content, regenerate = false, attachments = []) => {
    if (aborter || (!regenerate && !editingMessageId && !content && !attachments.length)) return;
    if (!conversationId) await createConversation();
    const editMessageId = regenerate ? null : editingMessageId;
    let userOutput = null;
    if (!regenerate && !editMessageId) userOutput = bubble('user', content, null, true, attachments);
    else if (editMessageId) {
      const editedRow = [...messages.querySelectorAll('.message.user')].find(row => Number(row.dataset.messageId) === editMessageId);
      if (!editedRow) return;
      const target = editedRow.querySelector('.message-content');
      const originalGallery = target.querySelector('.message-images');
      editedRow.dataset.content = content;
      renderContent(target, content);
      if (attachments.length) renderAttachments(target, attachments);
      else if (originalGallery) target.appendChild(originalGallery);
      let following = editedRow.nextElementSibling;
      while (following) {
        const next = following.nextElementSibling;
        following.remove();
        following = next;
      }
    } else messages.querySelector('.message.assistant:last-of-type')?.remove();
    prompt.value = ''; prompt.style.height = 'auto';
    const output = bubble('assistant', '', null, false);
    showThinking(output);
    aborter = new AbortController(); stop.hidden = false; send.disabled = true;
    let answer = '';
    try {
      const response = await fetch('/api/chat', {
        method: 'POST', headers: {'Content-Type':'application/json'}, signal:aborter.signal,
        body: JSON.stringify({conversation_id:conversationId, content, attachments, regenerate, edit_message_id:editMessageId, reasoning_effort:effectiveReasoning(), csrf_token:csrf})
      });
      if (!response.ok) {
        const err = await response.json();
        throw new Error(err.error?.message || err.detail || 'Generation failed');
      }
      const persistedUserMessageId = response.headers.get('X-AI-User-Message-ID');
      if (userOutput && persistedUserMessageId) {
        userOutput.row.dataset.messageId = persistedUserMessageId;
        addUserActions(userOutput.actions, userOutput.row);
      }
      if (!regenerate) clearPendingImages();
      if (editMessageId) clearEditing();
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';
      while (true) {
        const {value, done} = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, {stream:true});
        const events = buffer.split('\n\n');
        buffer = events.pop();
        for (const event of events) {
          for (const line of event.split('\n')) {
            if (!line.startsWith('data: ') || line === 'data: [DONE]') continue;
            try {
              const data = JSON.parse(line.slice(6));
              for (const choice of data.choices || []) {
                const contentDelta = choice.delta?.content || '';
                if (!contentDelta) continue;
                if (!answer) clearThinking(output);
                answer += contentDelta;
                output.row.dataset.content = answer;
                renderContent(output.target, answer);
                messages.scrollTop = messages.scrollHeight;
              }
            } catch (_) {}
          }
        }
      }
      if (!answer) {
        clearThinking(output);
        output.row.dataset.content = translate('No response was generated.');
        renderContent(output.target, output.row.dataset.content);
      }
      await refreshConversationList();
    } catch (error) {
      clearThinking(output);
      if (error.name === 'AbortError') {
        if (!answer) output.row.remove();
      } else {
        output.row.dataset.content = `Error: ${error.message}`;
        renderContent(output.target, output.row.dataset.content);
        if (editMessageId) await loadConversation(conversationId);
      }
    } finally {
      if (output.row.isConnected && output.row.dataset.content) addAssistantActions(output.actions, output.row);
      aborter = null; stop.hidden = true; send.disabled = false; syncImageAvailability();
    }
  };

  document.querySelectorAll('.conversation').forEach(button => button.addEventListener('click', () => loadConversation(button.dataset.id)));
  document.getElementById('new-chat').addEventListener('click', () => {
    conversationId = null;
    history.replaceState({}, '', '/');
    clearPendingImages();
    emptyState();
  });
  rename.addEventListener('click', async () => {
    if (!conversationId) return;
    const title = window.prompt('Conversation title', document.getElementById('chat-title').textContent);
    if (!title) return;
    const response = await fetch(`/api/conversations/${conversationId}`, {
      method:'PATCH', headers:{'Content-Type':'application/json'}, body:JSON.stringify({title, csrf_token:csrf})
    });
    if (response.ok) {
      document.getElementById('chat-title').textContent = (await response.json()).title;
      await refreshConversationList();
    }
  });
  remove.addEventListener('click', async () => {
    if (!conversationId || !window.confirm('Delete this conversation permanently?')) return;
    const response = await fetch(`/api/conversations/${conversationId}`, {
      method:'DELETE', headers:{'Content-Type':'application/json'}, body:JSON.stringify({csrf_token:csrf})
    });
    if (response.ok) {
      conversationId = null; history.replaceState({}, '', '/'); emptyState(); await refreshConversationList();
    }
  });
  stop.addEventListener('click', () => aborter?.abort());
  model.addEventListener('change', () => { syncReasoningAvailability(); syncImageAvailability(); });
  reasoning.addEventListener('change', async () => {
    const selected = reasoning.value;
    reasoning.disabled = true;
    reasoningSaveState.classList.remove('error');
    reasoningSaveState.textContent = 'Saving…';
    try {
      const response = await fetch('/api/preferences/reasoning', {
        method:'POST', headers:{'Content-Type':'application/json'},
        body:JSON.stringify({reasoning_effort:selected, csrf_token:csrf})
      });
      if (!response.ok) throw new Error('Unable to save reasoning preference');
      const data = await response.json();
      savedReasoning = data.reasoning_effort;
      reasoning.value = savedReasoning;
      reasoning.dataset.savedValue = savedReasoning;
      reasoningSaveState.textContent = 'Saved';
      setTimeout(() => {
        if (!reasoningSaveState.classList.contains('error')) reasoningSaveState.textContent = '';
      }, 1600);
    } catch (error) {
      reasoning.value = savedReasoning;
      reasoningSaveState.classList.add('error');
      reasoningSaveState.textContent = 'Unable to save';
      console.warn(error);
    } finally {
      syncReasoningAvailability();
    }
  });
  prompt.addEventListener('input', () => {
    prompt.style.height = 'auto';
    prompt.style.height = `${Math.min(prompt.scrollHeight, 180)}px`;
  });
  prompt.addEventListener('keydown', event => {
    if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); composer.requestSubmit(); }
  });
  imagePicker.addEventListener('click', () => imageInput.click());
  imageInput.addEventListener('change', async () => {
    const files = [...imageInput.files];
    imageInput.value = '';
    if (!modelSupportsVision()) return syncImageAvailability();
    imageStatusError = '';
    for (const file of files) {
      if (pendingImages.length >= MAX_IMAGES) {
        imageStatusError = `Attach no more than ${MAX_IMAGES} images.`;
        break;
      }
      if (!['image/png', 'image/jpeg', 'image/webp'].includes(file.type) || file.size <= 0 || file.size > MAX_IMAGE_BYTES) {
        imageStatusError = 'Each image must be PNG, JPEG or WebP and no larger than 20 MB.';
        continue;
      }
      const total = pendingImages.reduce((sum, item) => sum + item.size, 0) + file.size;
      if (total > MAX_TOTAL_IMAGE_BYTES) {
        imageStatusError = 'The combined image size cannot exceed 60 MB.';
        break;
      }
      const dataUrl = await new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = () => reject(reader.error);
        reader.readAsDataURL(file);
      });
      pendingImages.push({name:file.name, media_type:file.type, data_url:dataUrl, size:file.size});
    }
    renderPendingImages();
    syncImageAvailability();
  });
  composer.addEventListener('submit', async event => {
    event.preventDefault();
    const content = prompt.value.trim();
    await generate(content, false, pendingImages.map(({name, media_type, data_url}) => ({name, media_type, data_url})));
  });

  const initial = new URLSearchParams(location.search).get('conversation');
  syncReasoningAvailability();
  syncImageAvailability();
  if (initial) loadConversation(initial);
})();
