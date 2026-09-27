"use client";

import { useEffect, useState, type ReactNode } from "react";

type Props = { children: ReactNode };

export function MobileNavDrawer({ children }: Props) {
  const [open, setOpen] = useState(false);

  useEffect(() => {
    if (!open) return;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") setOpen(false);
    };
    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, [open]);

  useEffect(() => {
    document.body.classList.toggle("mobile-drawer-open", open);
    return () => document.body.classList.remove("mobile-drawer-open");
  }, [open]);

  return (
    <div className="mobile-menu">
      <button
        type="button"
        className="mobile-menu-trigger"
        aria-label={open ? "Close navigation menu" : "Open navigation menu"}
        aria-expanded={open}
        onClick={() => setOpen((value) => !value)}
      >
        {open ? "×" : "☰"}
      </button>
      {open && (
        <>
          <button
            type="button"
            className="mobile-nav-backdrop"
            aria-label="Close navigation menu"
            onClick={() => setOpen(false)}
          />
          <div className="mobile-nav-panel" onClick={(event) => {
            const target = event.target as HTMLElement;
            if (target.closest("a")) setOpen(false);
          }}>
            {children}
          </div>
        </>
      )}
    </div>
  );
}
