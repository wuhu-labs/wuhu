const chinese = document.documentElement.lang === 'zh-CN'
for (const button of document.querySelectorAll('.copy')) {
  button.addEventListener('click', async () => {
    const code = button.closest('.code-block').querySelector('code').textContent
    try {
      await navigator.clipboard.writeText(code)
      button.textContent = chinese ? '已复制' : 'Copied'
      button.dataset.copied = ''
    } catch {
      button.textContent = chinese ? '复制失败' : 'Copy failed'
    }
    setTimeout(() => {
      button.textContent = chinese ? '复制' : 'Copy'
      delete button.dataset.copied
    }, 1800)
  })
}
