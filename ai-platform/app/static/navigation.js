(() => {
  const menus = [...document.querySelectorAll('.topbar details')];
  if (!menus.length) return;

  menus.forEach(menu => menu.addEventListener('toggle', () => {
    if (!menu.open) return;
    menus.forEach(other => {
      if (other !== menu) other.open = false;
    });
  }));

  document.addEventListener('click', event => {
    menus.forEach(menu => {
      if (menu.open && !menu.contains(event.target)) menu.open = false;
    });
  });
  document.addEventListener('keydown', event => {
    if (event.key !== 'Escape') return;
    menus.forEach(menu => { menu.open = false; });
  });
})();
