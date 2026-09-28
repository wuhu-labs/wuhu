import { type ReactNode, useEffect, useState } from 'react'
import { createRoot } from 'react-dom/client'
import './app.css'
import './pages/artifact.css'
import './pages/blocks.css'
import './pages/doc.css'
import './pages/peek.css'
import { LabChrome, type LabPage } from './chrome.tsx'
import { BlocksPage } from './pages/blocks.tsx'
import { DocPage } from './pages/doc.tsx'
import { PeekComposer, PeekPage } from './pages/peek.tsx'
import { StudyPage } from './pages/study.tsx'
import { TokensPage } from './pages/tokens.tsx'

interface Route {
  page: LabPage
  leaf: string
  path: string[]
  content: ReactNode
  composer?: ReactNode
}

const routes: Record<string, Route> = {
  '/': {
    page: 'study',
    leaf: 'app-chrome-study.html',
    path: ['design'],
    content: <StudyPage />,
  },
  '/tokens': {
    page: 'tokens',
    leaf: 'tokens.html',
    path: ['design'],
    content: <TokensPage />,
  },
  '/doc': {
    page: 'doc',
    leaf: 'backups.md',
    path: ['ops'],
    content: <DocPage />,
  },
  '/peek': {
    page: 'peek',
    leaf: 'backups.md',
    path: ['ops'],
    content: <PeekPage />,
    composer: <PeekComposer />,
  },
  '/blocks': {
    page: 'blocks',
    leaf: 'blocks.md',
    path: ['design'],
    content: <BlocksPage />,
  },
}

function usePathname(): [string, (to: string) => void] {
  const [pathname, setPathname] = useState(() => globalThis.location.pathname)
  useEffect(() => {
    const onPop = () => setPathname(globalThis.location.pathname)
    globalThis.addEventListener('popstate', onPop)
    return () => globalThis.removeEventListener('popstate', onPop)
  }, [])
  const navigate = (to: string) => {
    if (to === globalThis.location.pathname) return
    globalThis.history.pushState(null, '', to)
    setPathname(to)
  }
  return [pathname, navigate]
}

function App() {
  const [pathname, navigate] = usePathname()
  const route = routes[pathname] ?? routes['/']
  return (
    <LabChrome
      page={route.page}
      leaf={route.leaf}
      path={route.path}
      navigate={navigate}
      composer={route.composer}
    >
      {route.content}
    </LabChrome>
  )
}

createRoot(document.getElementById('root')!).render(<App />)
