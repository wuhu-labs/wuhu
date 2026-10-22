import type { RouteConfig } from '@react-router/dev/routes'
import { spaceRoutes } from './space-routes.ts'

export default [...spaceRoutes] satisfies RouteConfig
