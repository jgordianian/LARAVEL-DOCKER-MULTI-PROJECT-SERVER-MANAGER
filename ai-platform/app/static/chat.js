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
  let imageStatusError = '';
  const MAX_IMAGES = 4;
  const MAX_IMAGE_BYTES = 2 * 1024 * 1024;
  const MAX_TOTAL_IMAGE_BYTES = 5 * 1024 * 1024 / 2;

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
        : (pendingImages.length ? `${pendingImages.length} of ${MAX_IMAGES} images ready` : 'PNG, JPEG or WebP · 2 MB per image');
  };

  const escapeHtml = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const highlight = value => value.replace(/\b(const|let|var|function|class|def|return|if|else|for|while|async|await|import|from|try|catch|except|true|false|null|None)\b/g, '<span class="syntax-keyword">$1</span>');
  const markdown = value => {
    let safe = escapeHtml(value);
    safe = safe.replace(/```([\w-]*)\n([\s\S]*?)```/g, (_, lang, code) =>
      `<pre><button type="button" class="copy-code">Copy</button><code data-lang="${lang}">${highlight(code)}</code></pre>`);
    safe = safe.replace(/`([^`]+)`/g, '<code>$1</code>');
    safe = safe.replace(new RegExp('\\\\*\\\\*([^*]+)\\\\*\\\\*', 'g'), '<strong>$1</strong>');
    return safe.replace(/\n/g, '<br>');
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
  const bubble = (role, content = '', createdAt = null, final = true, attachments = []) => {
    messages.querySelector('.empty')?.remove();
    const row = document.createElement('div');
    row.className = `message ${role}`;
    row.dataset.content = content;
    row.innerHTML = `<div class="avatar">${role === 'assistant' ? 'AI' : 'YOU'}</div><div><div class="message-content"></div><div class="message-meta"><time></time><span class="message-actions"></span></div></div>`;
    const target = row.querySelector('.message-content');
    renderContent(target, content);
    renderAttachments(target, attachments);
    row.querySelector('time').textContent = createdAt ? new Date(createdAt).toLocaleString() : new Date().toLocaleTimeString();
    const actions = row.querySelector('.message-actions');
    if (role === 'user') {
      const edit = document.createElement('button');
      edit.type = 'button'; edit.textContent = 'Edit & resend';
      edit.addEventListener('click', () => { prompt.value = row.dataset.content; prompt.focus(); });
      actions.appendChild(edit);
    } else if (final) {
      addAssistantActions(actions, row);
    }
    messages.appendChild(row);
    messages.scrollTop = messages.scrollHeight;
    return {target, row, actions};
  };
  const emptyState = () => {
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
    conversationId = data.id;
    model.value = data.model;
    syncReasoningAvailability();
    clearPendingImages();
    syncImageAvailability();
    document.getElementById('chat-title').textContent = data.title;
    rename.hidden = false; remove.hidden = false;
    messages.innerHTML = '';
    data.messages.forEach(item => bubble(item.role, item.content, item.created_at, true, item.attachments));
    document.querySelectorAll('.conversation').forEach(button => button.classList.toggle('active', Number(button.dataset.id) === data.id));
    history.replaceState({}, '', `/?conversation=${conversationId}`);
  };
  const generate = async (content, regenerate = false, attachments = []) => {
    if (aborter || (!regenerate && !content && !attachments.length)) return;
    if (!conversationId) await createConversation();
    if (!regenerate) bubble('user', content, null, true, attachments);
    else messages.querySelector('.message.assistant:last-of-type')?.remove();
    prompt.value = ''; prompt.style.height = 'auto';
    const output = bubble('assistant', '', null, false);
    aborter = new AbortController(); stop.hidden = false; send.disabled = true;
    try {
      const response = await fetch('/api/chat', {
        method: 'POST', headers: {'Content-Type':'application/json'}, signal:aborter.signal,
        body: JSON.stringify({conversation_id:conversationId, content, attachments, regenerate, reasoning_effort:effectiveReasoning(), csrf_token:csrf})
      });
      if (!response.ok) {
        const err = await response.json();
        throw new Error(err.error?.message || err.detail || 'Generation failed');
      }
      if (!regenerate) clearPendingImages();
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '', answer = '';
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
                answer += choice.delta?.content || '';
                output.row.dataset.content = answer;
                renderContent(output.target, answer);
                messages.scrollTop = messages.scrollHeight;
              }
            } catch (_) {}
          }
        }
      }
      addAssistantActions(output.actions, output.row);
      await refreshConversationList();
    } catch (error) {
      if (error.name !== 'AbortError') {
        output.row.dataset.content = `Error: ${error.message}`;
        renderContent(output.target, output.row.dataset.content);
      }
    } finally {
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
        imageStatusError = 'Each image must be PNG, JPEG or WebP and no larger than 2 MB.';
        continue;
      }
      const total = pendingImages.reduce((sum, item) => sum + item.size, 0) + file.size;
      if (total > MAX_TOTAL_IMAGE_BYTES) {
        imageStatusError = 'The combined image size cannot exceed 2.5 MB.';
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
