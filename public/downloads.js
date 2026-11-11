// Download links for download.html and android.html. gatekeeper looks up the newest nightly
// with its own token. The links go straight to GitHub, which serves the file to sponsors and
// 404 to everyone else. Without this the links stay on the release list.
const el = id => document.getElementById(id);
fetch('https://gatekeeper.debridmediamanager.com/api/downloads')
  .then(r => r.ok ? r.json() : Promise.reject(r.status))
  .then(d => {
    document.querySelectorAll('a[data-file]').forEach(a => { if (d.files[a.dataset.file]) a.href = d.files[a.dataset.file]; });
    if (el('tag')) el('tag').textContent = d.tag;
    if (el('build')) el('build').hidden = false;
  })
  .catch(() => { if (el('offline')) el('offline').hidden = false; });
document.querySelectorAll('.dl-copy button').forEach(b => b.addEventListener('click', () => {
  navigator.clipboard.writeText(b.previousElementSibling.textContent).then(() => {
    const label = b.dataset.label ??= b.textContent; // the page's own word for Copy, in whatever language it is
    b.textContent = '✓';
    setTimeout(() => { b.textContent = label; }, 2000);
  });
}));
