import { type ReactNode, useEffect, useRef } from 'react'

export function ModalDialog({
  open,
  title,
  onClose,
  children,
}: {
  open: boolean
  title: string
  onClose: () => void
  children: ReactNode
}) {
  const dialog = useRef<HTMLDialogElement>(null)

  useEffect(() => {
    const el = dialog.current
    if (el == null) return
    if (open && !el.open) el.showModal()
    if (!open && el.open) el.close()
  }, [open])

  // The shell listens on document and reads Escape as "show the sidebar";
  // React's own listener sits on document too, so only a native listener here
  // keeps a dialog's Escape from opening it underneath.
  useEffect(() => {
    const el = dialog.current
    if (el == null) return
    const contain = (event: KeyboardEvent) => {
      if (event.key === 'Escape') event.stopPropagation()
    }
    el.addEventListener('keydown', contain)
    return () => el.removeEventListener('keydown', contain)
  }, [])

  return (
    <dialog
      ref={dialog}
      className='wuhu-composer-dialog'
      aria-label={title}
      onClose={onClose}
    >
      {open && (
        <div className='wuhu-composer-dialog-body'>
          <h2 className='wuhu-dialog-title'>{title}</h2>
          {children}
        </div>
      )}
    </dialog>
  )
}
