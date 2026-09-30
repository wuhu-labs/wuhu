import { route, type RouteConfig } from '@react-router/dev/routes'
import { spaceRoutes } from './space-routes.ts'

const routes: RouteConfig = [...spaceRoutes]

// Dev-only design gallery; excluded from the production bundle.
if (import.meta.env.DEV) {
  routes.push(route('/_/dev/gallery', 'routes/dev-gallery.tsx'))
}

export default routes
