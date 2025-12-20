# Frontend Feature Checklist (Mastodon / Pleroma / Twitter‑like)

This is a **web UI** checklist for Pleroma‑Redux. Items are ordered roughly by dependency + what typically matters most for a “daily driver” UI.

## Legend
- **DONE**: implemented end‑to‑end in the web UI
- **PARTIAL**: exists, but incomplete/rough/missing polish or coverage
- **TODO**: not implemented in the web UI

## Current UI entry points (for reference)
- `/` (LiveView) timeline + compose + follow tooling
- `/notifications` (LiveView) notifications list
- `/@:nickname` (LiveView) profile view
- `/login`, `/register`, `/settings`, `/oauth/authorize` (controllers/templates)

---

## P0 — Core “daily driver” UX

### App shell, navigation, and layout
| Feature | Status | Notes |
|---|---:|---|
| Responsive layout (desktop + mobile) | PARTIAL | `AppShell` exists (bottom nav on mobile) but layout needs a cohesive, world‑class information architecture across all screens. |
| Global navigation (timeline / notifications / profile / settings) | PARTIAL | Implemented in `AppShell`, but not uniformly applied to all non‑LiveView pages (login/register/settings are separate templates). |
| “Compose” quick access on mobile (FAB / sheet) | PARTIAL | A mobile compose affordance exists, but compose is still basic and lacks attachments/etc. |
| Light/dark/system theme toggle | DONE | Theme toggle exists in layout; keep improving contrast + consistency. |
| Flash/toast feedback on user actions | PARTIAL | Controllers use flash; LiveView actions should consistently show success/error (and reduce silent failures). |
| Consistent button affordances (hover/focus/cursor/disabled) | PARTIAL | Some UI elements still feel non‑interactive; standardize via components. |
| Consistent design system components (Button, Card, Input, Avatar, etc.) | PARTIAL | Components exist, but not used everywhere (class duplication). |

### Authentication and account basics
| Feature | Status | Notes |
|---|---:|---|
| Register local account | DONE | `/register` |
| Login / logout | DONE | `/login`, `/logout` |
| Session persistence and “current user” rendering | DONE | Browser session + layout rendering works. |
| OAuth authorize UI | DONE | `/oauth/authorize` |
| Password reset flow (“forgot password”) | TODO | Email + token + reset UI. |
| Two‑factor auth (TOTP/WebAuthn) | TODO | Optional but common on serious instances. |
| Account switching (multi‑account UI) | TODO | Common power‑user feature. |

### Timeline reading (home/public)
| Feature | Status | Notes |
|---|---:|---|
| Public timeline view | DONE | `/` with timeline selector. |
| Home timeline view | DONE | Requires account; toggles exist. |
| Load more / pagination | DONE | “Load more” exists; consider infinite scroll later. |
| Infinite scroll | TODO | Replace/augment “Load more”. |
| Streaming new posts into timeline | DONE | Live updates exist for timeline. |
| “New posts” indicator when scrolled | TODO | Prevents disrupting reading when live updates arrive. |
| Human‑friendly timestamps (“5m”, “2h”) | TODO | Current formatting is raw datetime strings. |
| Status permalink page (single post view) | TODO | Needed for sharing, thread navigation, and deep links. |
| Thread/context view (replies chain) | TODO | Mastodon “context” equivalent in UI. |
| Clickable actor profile from timeline | TODO | Status cards don’t link actor → profile yet. |
| Link handling (open external safely, copy link) | TODO | UI affordances for sharing/copying/opening. |

### Compose / posting
| Feature | Status | Notes |
|---|---:|---|
| Post text | DONE | Basic compose exists. |
| Post validation feedback (empty/too long/etc) | PARTIAL | Empty handled; expand to full validations + inline errors. |
| Attachments upload (images) | TODO | Should use LiveView uploads + `MediaStorage`. |
| Attachments upload (video/audio) | TODO | Support UX + transcoding/probing later. |
| Attachment preview grid in composer | TODO | Must show selected media before posting. |
| Attachment alt text / description editing | TODO | Critical for accessibility; align with Mastodon API behavior. |
| Content warning / spoiler text | TODO | UX for CW and summary field. |
| Mark media as sensitive | TODO | UI for sensitive flag and blur previews. |
| Visibility selector (public/unlisted/followers/direct) | TODO | Backend supports visibility; UI needs it. |
| Reply composer (in‑reply‑to) | TODO | Compose from status card. |
| Quote post | TODO | Optional; not in vanilla Mastodon but common. |
| Drafts | TODO | Often requested; can be lightweight (local storage). |
| Polls | TODO | Mastodon‑style polls (optional). |
| Scheduled posts | TODO | Optional. |

### Status rendering (the post card)
| Feature | Status | Notes |
|---|---:|---|
| Safe HTML rendering (sanitized) | DONE | Rendering uses safe HTML pipeline. |
| Local text rendering | DONE | Local posts render as text. |
| Linkify mentions/hashtags for local content | TODO | Make `@user@host` and `#tag` clickable. |
| Emoji reactions UI | DONE | Limited emoji set; improve UX (picker/custom emoji). |
| Like / unlike | DONE | |
| Repost / unrepost | DONE | |
| Reply action | TODO | Requires reply compose + thread view. |
| Bookmark action | TODO | |
| Delete own post | TODO | |
| Edit own post | TODO | (Optional; Mastodon doesn’t support editing by default.) |
| Report post/user action menu | TODO | Common “…” menu. |
| Media attachments render | PARTIAL | Attachments render, but currently image‑only and no lightbox/video/audio handling. |
| Attachment lightbox / media viewer | TODO | Click to view full media, navigate carousel. |
| Cards for link previews (OpenGraph) | TODO | “Twitter cards” / link previews (optional). |
| Content collapse (long posts) | TODO | Readability + performance. |

---

## P1 — Social graph + discovery + notifications

### Profiles and relationships
| Feature | Status | Notes |
|---|---:|---|
| Profile page | DONE | `/@:nickname` |
| Follow / unfollow from profile | DONE | |
| Remote follow by handle | DONE | Present as a “follow remote” workflow. |
| Followers list page | TODO | Dedicated list view with pagination. |
| Following list page | PARTIAL | A “following” panel exists; needs dedicated pages + better UX. |
| Follow requests (locked accounts) | TODO | Accept/deny UI. |
| Blocks / mutes | TODO | UI + clear state indicators. |
| Relationship badges (follows you, mutuals) | TODO | Optional but useful. |
| Profile fields (custom metadata) | TODO | Common on Mastodon/Pleroma. |
| Profile header image | TODO | |

### Notifications
| Feature | Status | Notes |
|---|---:|---|
| Notifications list | DONE | `/notifications` |
| Notification types coverage | PARTIAL | Follow/like/repost covered; expand (mentions, emoji reactions, etc.). |
| Live updates for notifications | TODO | Subscribe + stream updates. |
| Mark as read / unread | TODO | |
| Notification filtering (mentions only, follows only, etc.) | TODO | |

### Search & discovery
| Feature | Status | Notes |
|---|---:|---|
| Search box (global) | TODO | Accounts + statuses + hashtags. |
| Account lookup by `@user@host` | TODO | Separate from “follow by handle” workflow. |
| Hashtag pages | TODO | |
| Explore / trending | TODO | |
| User directory | TODO | |

### Messaging
| Feature | Status | Notes |
|---|---:|---|
| Direct messages UI | TODO | Mastodon DMs are “direct visibility” statuses; UI still needs it. |

---

## P2 — Quality bar (polish, accessibility, performance)

### Accessibility (A11y)
| Feature | Status | Notes |
|---|---:|---|
| Keyboard navigation for all primary flows | PARTIAL | Needs systematic review + tests. |
| Focus visible and consistent | PARTIAL | Standardize focus rings and focus traps (modals). |
| Icon buttons have labels (`aria-label`) | PARTIAL | Some do; enforce everywhere. |
| Reduced motion support | TODO | Respect `prefers-reduced-motion`. |
| High contrast checks (light/dark) | PARTIAL | Validate contrast ratios. |

### Performance / perceived performance
| Feature | Status | Notes |
|---|---:|---|
| Skeleton loading states | TODO | For timelines, profile posts, notifications. |
| Optimistic UI (safe actions) | PARTIAL | Likes/reposts could be optimistic with rollback. |
| Image lazy loading and sizing | PARTIAL | `loading="lazy"` exists; add aspect ratio, srcset, etc. |
| Offline/failed network UI | TODO | “Retry” affordances for failed actions. |

### Product polish
| Feature | Status | Notes |
|---|---:|---|
| Consistent empty states | PARTIAL | Some screens have empty states; unify style and messaging. |
| Consistent error states (inline + toast) | PARTIAL | Avoid silent failures. |
| Consistent copywriting / micro‑interactions | PARTIAL | Make the app feel cohesive and premium. |

---

## Out‑of‑scope (for now) but common on “big” platforms
| Feature | Status | Notes |
|---|---:|---|
| Lists (Mastodon lists) | TODO | Might be important for power users. |
| Bookmarks / favourites pages | TODO | |
| Filters (mute words, hide boosts, etc.) | TODO | |
| Analytics / insights | TODO | |
| Admin/mod UI in web | TODO | |

