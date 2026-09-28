import {
  isRouteErrorResponse,
  Links,
  Meta,
  Outlet,
  Scripts,
  ScrollRestoration,
} from 'react-router'

import { useEffect } from 'react'
import type { Route } from './+types/root'
import { registerServiceWorker } from './sdk/service-worker'
import './app.css'

export function Layout({ children }: { children: React.ReactNode }) {
  return (
    <html lang='en'>
      <head>
        <meta charSet='utf-8' />
        <meta
          name='viewport'
          content='width=device-width, initial-scale=1, viewport-fit=cover'
        />
        <meta name='apple-mobile-web-app-capable' content='yes' />
        <meta
          name='apple-mobile-web-app-status-bar-style'
          content='black-translucent'
        />
        <meta name='apple-mobile-web-app-title' content='Wuhu' />
        <link rel='icon' href='/_/favicon.ico' />
        <link rel='manifest' href='/_/manifest.webmanifest' />
        <link rel='apple-touch-icon' href='/_/apple-touch-icon.png' />
        <Meta />
        <Links />
      </head>
      <body>
        {children}
        <ScrollRestoration />
        <Scripts />
      </body>
    </html>
  )
}

export default function App() {
  useEffect(() => {
    if ('serviceWorker' in navigator) void registerServiceWorker()
  }, [])
  return <Outlet />
}

export function HydrateFallback() {
  return null
}

export function ErrorBoundary({ error }: Route.ErrorBoundaryProps) {
  let message = 'Error'
  let details = 'An unexpected error occurred.'
  let stack: string | undefined

  if (isRouteErrorResponse(error)) {
    message = error.status === 404 ? '404' : 'Error'
    details = error.status === 404
      ? 'The requested page could not be found.'
      : error.statusText || details
  } else if (import.meta.env.DEV && error && error instanceof Error) {
    details = error.message
    stack = error.stack
  }

  return (
    <main className='wuhu-standalone container mx-auto pt-16'>
      <h1>{message}</h1>
      <p>{details}</p>
      {stack && (
        <pre className='w-full p-4 overflow-x-auto'>
          <code>{stack}</code>
        </pre>
      )}
    </main>
  )
}
