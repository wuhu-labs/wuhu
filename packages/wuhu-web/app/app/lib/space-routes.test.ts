import type { RouteConfigEntry } from '@react-router/dev/routes'
import { matchRoutes, type RouteObject } from 'react-router'
import { spaceRoutes } from '../space-routes.ts'

function routeObjects(entries: RouteConfigEntry[]): RouteObject[] {
  return entries.map(({ id, file, path, index, children }) =>
    index
      ? { id: id ?? file, index: true }
      : { id: id ?? file, path, children: routeObjects(children ?? []) }
  )
}

function leaf(pathname: string): string | undefined {
  return matchRoutes(routeObjects(spaceRoutes), pathname)?.at(-1)?.route.id
}

Deno.test('/ is the space index route, which renders the node page', () => {
  if (leaf('/') !== 'routes/home') throw new Error(`/ matched ${leaf('/')}`)
})

Deno.test('a path below / still renders the node page', () => {
  const matched = leaf('/notes/plan.md')
  if (matched !== 'routes/node.tsx') {
    throw new Error(`/notes/plan.md matched ${matched}`)
  }
})
