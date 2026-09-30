(() => {
  const root = document.getElementById('codex-setup-root');
  const dialog = document.getElementById('codex-setup-dialog');
  if (!root || !dialog) return;

  const installerUrl = root.dataset.installerUrl || '';
  const createdKeyId = root.dataset.createdKeyId || '';
  const createdSecret = document.getElementById('created-secret-value')?.textContent.trim() || '';
  const keyInput = document.getElementById('codex-api-key');
  const commandNode = document.getElementById('codex-install-command');
  const copyButton = document.getElementById('codex-copy-command');
  const status = document.getElementById('codex-command-status');
  const platformButtons = [...dialog.querySelectorAll('[data-platform]')];
  const translate = value => window.aiTranslate ? window.aiTranslate(value) : value;

  const detectedPlatform = () => {
    const value = `${navigator.userAgentData?.platform || ''} ${navigator.platform || ''}`.toLowerCase();
    if (value.includes('mac')) return 'macos';
    if (value.includes('linux')) return 'linux';
    return 'windows';
  };

  let platform = localStorage.getItem('omnivis.codex.platform') || detectedPlatform();
  if (!['windows', 'linux', 'macos'].includes(platform)) platform = 'windows';

  const shellQuote = value => `'${value.replaceAll("'", `'"'"'`)}'`;
  const powershellQuote = value => `'${value.replaceAll("'", "''")}'`;
  const endpointFor = value => {
    const url = new URL(installerUrl, window.location.origin);
    url.searchParams.set('platform', value);
    return url.toString();
  };

  const renderCommand = () => {
    platformButtons.forEach(button => {
      const selected = button.dataset.platform === platform;
      button.classList.toggle('selected', selected);
      button.setAttribute('aria-pressed', selected ? 'true' : 'false');
    });
    const apiKey = keyInput.value.trim();
    if (!apiKey) {
      commandNode.textContent = translate('Enter the complete API key to generate the command.');
      copyButton.disabled = true;
      status.textContent = translate('Enter the complete API key to generate the command.');
      return;
    }
    const endpoint = endpointFor(platform);
    if (platform === 'windows') {
      commandNode.textContent = `$env:OMNIVIS_CODING_API_KEY=${powershellQuote(apiKey)}; (Invoke-RestMethod -Uri ${powershellQuote(endpoint)} -Headers @{ Authorization = ('Bearer ' + $env:OMNIVIS_CODING_API_KEY) }) | Invoke-Expression`;
    } else {
      commandNode.textContent = `export OMNIVIS_CODING_API_KEY=${shellQuote(apiKey)}; curl -fsSL -H "Authorization: Bearer $OMNIVIS_CODING_API_KEY" ${shellQuote(endpoint)} | sh`;
    }
    copyButton.disabled = false;
    status.textContent = translate('Command ready. Run it in PowerShell or Terminal, then restart Visual Studio Code.');
  };

  const openDialog = button => {
    keyInput.value = button.dataset.keyId === createdKeyId ? createdSecret : '';
    dialog.dataset.keyName = button.dataset.keyName || '';
    renderCommand();
    dialog.showModal();
    if (!keyInput.value) keyInput.focus();
  };

  const closeDialog = () => {
    keyInput.value = '';
    commandNode.textContent = '';
    dialog.close();
  };

  document.querySelectorAll('.codex-setup-button').forEach(button => {
    button.addEventListener('click', () => openDialog(button));
  });
  platformButtons.forEach(button => {
    button.addEventListener('click', () => {
      platform = button.dataset.platform;
      localStorage.setItem('omnivis.codex.platform', platform);
      renderCommand();
    });
  });
  keyInput.addEventListener('input', renderCommand);
  dialog.querySelectorAll('.codex-dialog-close').forEach(button => button.addEventListener('click', closeDialog));
  dialog.addEventListener('click', event => {
    if (event.target === dialog) closeDialog();
  });
  dialog.addEventListener('cancel', event => {
    event.preventDefault();
    closeDialog();
  });
  copyButton.addEventListener('click', async () => {
    if (copyButton.disabled) return;
    try {
      await navigator.clipboard.writeText(commandNode.textContent);
    } catch (_) {
      const range = document.createRange();
      range.selectNodeContents(commandNode);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      document.execCommand('copy');
      selection.removeAllRanges();
    }
    status.textContent = translate('Command copied.');
  });
})();
