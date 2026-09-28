const paths = {
  plus: <path d='M12 5v14M5 12h14' />,
  search: (
    <>
      <circle cx='11' cy='11' r='6.5' />
      <path d='m16 16 4 4' />
    </>
  ),
  chevronUp: <path d='m6 14 6-6 6 6' />,
  chevronRight: <path d='m9 5 7 7-7 7' />,
  chevronDown: <path d='m6 10 6 6 6-6' />,
  check: <path d='m5 12.5 4.5 4.5L19 7.5' />,
  hammer: <path d='m9.5 6.5 3-3 8 8-3 3zM13.5 10.5 4 20' />,
  info: (
    <>
      <circle cx='12' cy='12' r='8.5' />
      <path d='M12 11v5.5M12 7.8v.2' />
    </>
  ),
  bookmark: <path d='M7 4h10v16l-5-4-5 4z' />,
  sparkle: (
    <path d='m12 4 1.8 5.2L19 11l-5.2 1.8L12 18l-1.8-5.2L5 11l5.2-1.8z' />
  ),
  rotate: <path d='M19 12a7 7 0 1 1-2.05-4.95M19 4v4h-4' />,
  reply: <path d='M5 5v6a4 4 0 0 0 4 4h10M15 11l4 4-4 4' />,
  warning: <path d='M12 4 3 20h18zM12 10v4.5M12 17.2v.2' />,
  table: (
    <>
      <rect x='4' y='5' width='16' height='14' rx='2' />
      <path d='M4 10h16M10 10v9' />
    </>
  ),
  message: (
    <path d='M20 15a2 2 0 0 1-2 2H8l-4 4V6a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2z' />
  ),
  home: <path d='m4 10 8-6 8 6v9H4zM9 19v-6h6v6' />,
  folder: <path d='M4 7h6l2 2h8v10H4z' />,
  note: <path d='M6 3h9l4 4v14H6zM15 3v5h4M9 12h7M9 16h5' />,
  plan: <path d='M6 3h12v18H6zM9 8h6M9 12h6M9 16h4' />,
  tokens: (
    <>
      <circle cx='8' cy='9' r='3.5' />
      <circle cx='16' cy='15' r='3.5' />
    </>
  ),
  archive: <path d='M5 8h14v11H5zM4 5h16v3H4zM10 12h4' />,
  unarchive: (
    <path d='M5 8h14v11H5zM4 5h16v3H4zM12 17v-6M9.5 13.5 12 11l2.5 2.5' />
  ),
  compact: <path d='M4 10h6V4M20 14h-6v6M10 10 4 4M14 14l6 6' />,
  restart: <path d='M5 12a7 7 0 1 0 2.1-5M5 4v4h4' />,
  gear: (
    <>
      <circle cx='12' cy='12' r='3' />
      <path d='M19 12a7 7 0 0 0-.08-1l2-1.5-2-3.5-2.4 1A8 8 0 0 0 15 6l-.3-2.6h-4L10.4 6A8 8 0 0 0 8.8 7L6.5 6l-2 3.5L6.6 11a7 7 0 0 0 0 2L4.5 14.5l2 3.5 2.3-1a8 8 0 0 0 1.6 1l.3 2.6h4L15 18a8 8 0 0 0 1.5-1l2.4 1 2-3.5-2-1.5a7 7 0 0 0 .1-1Z' />
    </>
  ),
  share: <path d='M12 15V4M8 8l4-4 4 4M5 13v7h14v-7' />,
  openApp: <path d='M14 4h6v6M20 4l-8 8M18 14v6H4V6h6' />,
  more: (
    <>
      <circle cx='5' cy='12' r='1' fill='currentColor' stroke='none' />
      <circle cx='12' cy='12' r='1' fill='currentColor' stroke='none' />
      <circle cx='19' cy='12' r='1' fill='currentColor' stroke='none' />
    </>
  ),
  sidebar: (
    <>
      <rect x='3.5' y='5' width='17' height='14' rx='3' />
      <path d='M9.5 5v14' />
    </>
  ),
  send: <path d='m5 12 14-7-5 14-2.5-5.5zM11.5 13.5 19 5' />,
  xmark: <path d='m6.5 6.5 11 11M17.5 6.5l-11 11' />,
  paperclip: (
    <path d='m20 11.5-7.8 7.8a5 5 0 0 1-7.1-7.1l8.2-8.2a3.3 3.3 0 0 1 4.7 4.7l-8.2 8.2a1.7 1.7 0 0 1-2.4-2.4l7.4-7.4' />
  ),
  mic: (
    <>
      <rect x='9' y='3' width='6' height='11' rx='3' />
      <path d='M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21' />
    </>
  ),
  stop: (
    <rect
      x='7'
      y='7'
      width='10'
      height='10'
      rx='1.5'
      fill='currentColor'
    />
  ),
}

export type IconName = keyof typeof paths

export function Icon({ name }: { name: IconName }) {
  return (
    <svg className='wui-icon' viewBox='0 0 24 24' aria-hidden='true'>
      {paths[name]}
    </svg>
  )
}
