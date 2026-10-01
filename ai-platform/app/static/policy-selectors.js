(() => {
  const values = raw => String(raw || '').split(',').map(value => value.trim()).filter(Boolean);

  document.querySelectorAll('[data-policy-form]').forEach(form => {
    const ownerType = form.querySelector('[data-owner-type]');
    const ownerId = form.querySelector('[data-owner-id]');
    const modelInputs = [...form.querySelectorAll('[data-policy-model]')];
    const scopeInputs = [...form.querySelectorAll('[data-policy-scope]')];

    const selectedOwner = () => ownerId?.options[ownerId.selectedIndex] || null;

    const syncOwners = () => {
      if (!ownerType || !ownerId) return;
      const type = ownerType.value;
      const options = [...ownerId.options];
      options.forEach(option => {
        const matches = option.dataset.ownerType === type;
        option.hidden = !matches;
        option.disabled = !matches;
      });
      if (selectedOwner()?.dataset.ownerType !== type) {
        const first = options.find(option => option.dataset.ownerType === type);
        if (first) ownerId.selectedIndex = options.indexOf(first);
      }
    };

    const syncPolicy = () => {
      syncOwners();
      const owner = selectedOwner();
      const serviceOwner = owner?.dataset.ownerType === 'service_account';
      const ownerModels = new Set(values(owner?.dataset.models));
      const ownerScopes = new Set(values(owner?.dataset.scopes));

      modelInputs.forEach(input => {
        const active = input.dataset.policyStale !== 'true';
        const ownerAllows = !serviceOwner || ownerModels.size === 0 || ownerModels.has(input.value);
        const permitted = active && ownerAllows;
        const preserved = input.dataset.policyExisting === 'true';
        input.disabled = !permitted && !preserved;
        input.closest('.policy-option')?.classList.toggle('unavailable', !permitted);
        if (!permitted && !preserved) input.checked = false;
      });

      const permittedModels = modelInputs.filter(input => !input.disabled && input.dataset.policyStale !== 'true');
      const selectedModels = permittedModels.filter(input => input.checked);
      const effectiveModels = selectedModels.length ? selectedModels : permittedModels;
      const availableScopes = new Set(['models']);
      effectiveModels.forEach(input => values(input.dataset.scopes).forEach(scope => availableScopes.add(scope)));

      scopeInputs.forEach(input => {
        const modelAllows = availableScopes.has(input.value);
        const ownerAllows = !serviceOwner || ownerScopes.size === 0 || ownerScopes.has(input.value);
        const permitted = modelAllows && ownerAllows;
        const preserved = input.dataset.policyExisting === 'true';
        input.disabled = !permitted && !preserved;
        input.closest('.policy-option')?.classList.toggle('unavailable', !permitted);
        if (!permitted && !preserved) input.checked = false;
      });
    };

    ownerType?.addEventListener('change', syncPolicy);
    ownerId?.addEventListener('change', syncPolicy);
    modelInputs.forEach(input => input.addEventListener('change', syncPolicy));
    syncPolicy();
  });
})();
