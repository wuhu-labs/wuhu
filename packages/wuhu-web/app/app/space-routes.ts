import { index, route, type RouteConfigEntry } from '@react-router/dev/routes'

export const spaceRoutes: RouteConfigEntry[] = [
  route('/_/enroll', 'routes/enroll.tsx'),
  route('/_/login', 'routes/login.tsx'),
  route('/', 'routes/space.tsx', [
    index('routes/node.tsx', { id: 'routes/home' }),
    route('_/sessions', 'routes/sessions.tsx'),
    route('_/settings', 'routes/settings.tsx'),
    route('_/templates', 'routes/templates.tsx'),
    route('_/system/*', 'routes/system.tsx'),
    route('_/sessions/:id', 'routes/session.tsx'),
    route('_/conversations/:id', 'routes/conversation.tsx'),
    route('*', 'routes/node.tsx'),
  ]),
]
