import type { ButtonHTMLAttributes, HTMLAttributes } from 'react'

// The one glass surface every chrome control is drawn on. It owns fill,
// border, shadow, blur, height and radius; a caller only lays out what is in
// it. `control` is the toolbar's 36px, `field` the composer row's 44px.
export type GlassSize = 'control' | 'field'

interface GlassLook {
  size?: GlassSize
  circle?: boolean
  solid?: boolean
}

function glassClass(
  { size = 'control', circle, solid }: GlassLook,
  extra?: string,
): string {
  return [
    'wui-glass',
    `wui-glass-${size}`,
    circle && 'wui-glass-circle',
    solid && 'wui-glass-solid',
    extra,
  ].filter(Boolean).join(' ')
}

export function Glass(
  { size, circle, solid, className, ...rest }:
    & GlassLook
    & HTMLAttributes<HTMLDivElement>,
) {
  return (
    <div className={glassClass({ size, circle, solid }, className)} {...rest} />
  )
}

export function GlassButton(
  { size, circle = true, solid, className, type = 'button', ...rest }:
    & GlassLook
    & ButtonHTMLAttributes<HTMLButtonElement>,
) {
  return (
    <button
      type={type}
      className={glassClass({ size, circle, solid }, className)}
      {...rest}
    />
  )
}
