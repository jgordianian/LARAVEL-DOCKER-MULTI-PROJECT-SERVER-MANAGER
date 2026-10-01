(() => {
  const input = document.getElementById('profile-photo-input');
  if (!input) return;
  const preview = document.getElementById('profile-photo-preview');
  const fallback = document.getElementById('profile-photo-fallback');
  const filename = document.getElementById('profile-photo-filename');
  let readSequence = 0;

  input.addEventListener('change', () => {
    const sequence = ++readSequence;
    const file = input.files?.[0];
    if (!file) {
      filename.textContent = window.aiTranslate ? window.aiTranslate('No file selected') : 'No file selected';
      return;
    }
    filename.textContent = file.name;
    const reader = new FileReader();
    reader.addEventListener('load', () => {
      if (sequence !== readSequence || typeof reader.result !== 'string') return;
      preview.src = reader.result;
      preview.hidden = false;
      if (fallback) fallback.hidden = true;
    });
    reader.readAsDataURL(file);
  });
})();
