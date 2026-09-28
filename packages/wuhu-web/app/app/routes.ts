import { route, type RouteConfig } from '@react-router/dev/routes'

const routes: RouteConfig = [
  route('/_/enroll', 'routes/enroll.tsx'),
  route('/_/login', 'routes/login.tsx'),
  route('/', 'routes/space.tsx', [
    route('_/sessions', 'routes/sessions.tsx'),
    route('_/settings', 'routes/settings.tsx'),
    route('_/templates', 'routes/templates.tsx'),
    route('_/system/*', 'routes/system.tsx'),
    route('_/sessions/:id', 'routes/session.tsx'),
    route('_/conversations/:id', 'routes/conversation.tsx'),
    route('*', 'routes/node.tsx'),
  ]),
]

// Dev-only design gallery; excluded from the production bundle.
if (import.meta.env.DEV) {
  routes.push(route('/_/dev/gallery', 'routes/dev-gallery.tsx'))
}

export default routes
