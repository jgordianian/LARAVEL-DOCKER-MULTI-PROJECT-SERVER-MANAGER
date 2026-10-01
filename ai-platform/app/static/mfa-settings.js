(() => {
  const mode = document.getElementById('mfa-challenge-mode');
  if (!mode) return;
  const update = () => {
    document.querySelectorAll('[data-mfa-mode]').forEach(element => {
      const visible = element.dataset.mfaMode === mode.value;
      element.hidden = !visible;
      const input = element.querySelector('input');
      if (input) input.required = visible;
    });
  };
  mode.addEventListener('change', update);
  update();
})();
