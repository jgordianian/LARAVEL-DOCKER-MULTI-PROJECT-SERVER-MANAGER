(() => {
  const translate = value => window.aiTranslate ? window.aiTranslate(value) : value;
  const refreshForm = document.querySelector('.catalog-refresh-form');
  if (refreshForm) {
    refreshForm.addEventListener('submit', () => {
      const button = refreshForm.querySelector('button');
      button.disabled = true;
      button.classList.add('is-refreshing');
      button.querySelector('span').textContent = translate('Updating catalog…');
    });
  }
  const pollInstallation = async element => {
    const activationOnly = element.dataset.installOperation === 'activation';
    try {
      const response = await fetch(element.dataset.installStatusUrl, {
        credentials: 'same-origin',
        headers: {'Accept': 'application/json'},
      });
      if (!response.ok) throw new Error('status unavailable');
      const data = await response.json();
      const message = element.querySelector('[data-install-message]');
      if (data.status === 'completed') {
        element.className = 'alert success model-install-progress';
        message.textContent = translate(activationOnly ? 'Model activated successfully.' : data.activation_requested ? 'Model installed and activated successfully.' : 'Model downloaded successfully.');
        const successUrl = element.dataset.installSuccessUrl;
        if (successUrl) {
          window.setTimeout(() => window.location.replace(successUrl), 700);
          return;
        }
        const result = data.activation_requested ? 'catalog-activated' : 'catalog-downloaded';
        window.setTimeout(() => window.location.replace(`/admin/models?result=${result}#model-${data.model_id}`), 700);
        return;
      }
      if (data.status === 'failed') {
        element.className = 'alert error model-install-progress';
        message.textContent = `${translate(activationOnly ? 'Background activation failed.' : 'Background installation failed.')} ${data.error || translate('Review the model details and retry the operation.')}`;
        return;
      }
      message.textContent = translate(
        data.status === 'queued'
          ? (activationOnly ? 'Activation queued…' : 'Installation queued…')
          : data.phase === 'activation'
            ? 'Download complete. Validating capacity and activating…'
            : 'Downloading pinned model weights…'
      );
    } catch (_error) {
      const message = element.querySelector('[data-install-message]');
      message.textContent = translate(activationOnly ? 'Activation continues in the background; reconnecting to status…' : 'Installation continues in the background; reconnecting to status…');
    }
    window.setTimeout(() => pollInstallation(element), 2500);
  };

  for (const element of document.querySelectorAll('[data-install-status-url]')) {
    window.setTimeout(() => pollInstallation(element), 250);
  }

  const form = document.querySelector('#guided-model-form');
  if (!form) return;

  const select = form.querySelector('#catalog-model-select');
  const alias = form.querySelector('#catalog-alias');
  const aliasStatus = form.querySelector('#catalog-alias-status');
  const existingAliases = new Set((form.dataset.existingAliases || '').split(',').filter(Boolean));
  const capabilitiesValue = form.querySelector('#catalog-capabilities-value');
  const capabilityInputs = [...form.querySelectorAll('.capability-choice input')];
  const download = form.querySelector('#catalog-download');
  const activate = form.querySelector('#catalog-activate');
  const makeDefault = form.querySelector('#catalog-default');
  const submit = form.querySelector('#catalog-submit');
  const capabilityReview = form.querySelector('#catalog-capability-review');
  const capabilitySource = form.querySelector('#catalog-capability-source');
  const fields = {
    name: form.querySelector('#catalog-display-name'),
    summary: form.querySelector('#catalog-summary'),
    category: form.querySelector('#catalog-category'),
    repository: form.querySelector('#catalog-repository'),
    revision: form.querySelector('#catalog-revision'),
    weight: form.querySelector('#catalog-weight'),
    vram: form.querySelector('#catalog-vram'),
    context: form.querySelector('#catalog-context'),
    reviewDate: form.querySelector('#catalog-review-date'),
    fit: form.querySelector('#catalog-fit'),
    fitDetail: form.querySelector('#catalog-fit-detail'),
  };

  const selectedData = () => {
    const option = select.options[select.selectedIndex];
    return option?.value ? option.dataset : null;
  };

  const syncCapabilities = () => {
    capabilitiesValue.value = capabilityInputs
      .filter(input => !input.disabled && input.checked)
      .map(input => input.value)
      .join(',');
  };

  const validateAlias = () => {
    const value = alias.value.trim().toLowerCase();
    const unavailable = existingAliases.has(value);
    const message = unavailable ? translate('This alias is already in use. Choose another one.') : '';
    alias.setCustomValidity(message);
    aliasStatus.textContent = message;
    aliasStatus.classList.toggle('error-text', unavailable);
  };

  const syncActions = () => {
    activate.disabled = !download.checked;
    if (!download.checked) activate.checked = false;
    makeDefault.disabled = !activate.checked;
    if (!activate.checked) makeDefault.checked = false;
    submit.textContent = translate(download.checked ? 'Register and download' : 'Register model');
  };

  const renderSelection = () => {
    const data = selectedData();
    submit.disabled = !data;
    if (!data) return;

    alias.value = data.alias;
    validateAlias();
    fields.name.textContent = data.name;
    fields.summary.textContent = data.summary;
    fields.category.textContent = data.category;
    fields.repository.textContent = data.repository;
    fields.revision.textContent = data.revision;
    fields.weight.textContent = `${data.weight} GB`;
    fields.vram.textContent = `${data.vram} GB`;
    fields.context.textContent = Number(data.context).toLocaleString();
    fields.reviewDate.textContent = data.capabilitiesReviewedAt;
    capabilityReview.textContent = `${translate('Capabilities reviewed for pinned revision')} · ${data.capabilitiesReviewedAt}`;
    capabilitySource.href = data.capabilitySource;
    fields.fit.textContent = translate(data.fit);
    fields.fit.className = `pill ${data.fit === 'FIT' ? 'good' : data.fit === 'TOO LARGE' ? 'bad' : 'warning'}`;
    fields.fitDetail.textContent = translate({
      FIT: 'Fits the detected hardware recommendation',
      TIGHT: 'Tight fit; live validation is required',
      'TOO LARGE': 'Too large for the detected GPU recommendation',
      UNKNOWN: 'GPU capacity could not be detected',
    }[data.fit] || 'GPU capacity could not be detected');

    const supported = new Set(data.capabilities.split(',').filter(Boolean));
    for (const input of capabilityInputs) {
      const wrapper = input.closest('.capability-choice');
      const available = supported.has(input.value);
      input.disabled = !available;
      input.checked = available;
      wrapper.hidden = !available;
    }
    activate.checked = data.fit === 'FIT';
    makeDefault.checked = false;
    syncCapabilities();
    syncActions();
  };

  select.addEventListener('change', renderSelection);
  alias.addEventListener('input', validateAlias);
  for (const input of capabilityInputs) input.addEventListener('change', syncCapabilities);
  download.addEventListener('change', syncActions);
  activate.addEventListener('change', syncActions);
  form.addEventListener('submit', event => {
    syncCapabilities();
    const data = selectedData();
    if (!data) {
      event.preventDefault();
      return;
    }
    if (activate.checked && data.fit === 'TOO LARGE' && !window.confirm(translate('This model exceeds the detected GPU recommendation. Continue to the live capacity validation?'))) {
      event.preventDefault();
      return;
    }
    submit.disabled = true;
    submit.textContent = translate(download.checked ? 'Starting installation…' : 'Registering…');
  });

  const firstAvailable = [...select.options].find(option => option.value && !option.disabled);
  if (firstAvailable) select.value = firstAvailable.value;
  renderSelection();
})();
