# UX Standards

These standards ensure applications are accessible, responsive, and consistent. Based on WCAG 2.2 AA, Material Design guidelines, and modern responsive design practices.

## Accessibility (WCAG 2.2 AA Baseline)

### Perceivable
- **Text contrast**: Minimum 4.5:1 for normal text, 3:1 for large text (18px+ or 14px+ bold). Use project design tokens — don't hardcode colors.
- **Non-text contrast**: UI components and graphical objects need 3:1 contrast against adjacent colors.
- **Alt text**: All informational images have descriptive `alt`. Decorative images use `alt=""`. Background images carrying meaning need a text alternative.
- **No color-only indicators**: Status, errors, and states must be conveyed through text, icons, or patterns — not color alone. A red border on an error field also needs an error message.
- **Motion**: Respect `prefers-reduced-motion`. Provide alternatives for content that relies on animation. No auto-playing video without controls.

### Operable
- **Keyboard access**: Every interactive element is reachable and operable via keyboard. No mouse-only interactions.
- **Focus visible**: Focus indicators are clearly visible (minimum 2px outline or equivalent). Never `outline: none` without a visible replacement.
- **Focus order**: Tab order follows visual order. No `tabindex > 0`. Use DOM order, not CSS to control sequence.
- **Focus management**: When modals open, focus moves into them. When they close, focus returns to the trigger. Dynamic content additions are announced or focused.
- **Touch targets**: Minimum 44x44 CSS pixels for touch devices. Add padding if the visible element is smaller.
- **No keyboard traps**: Users can always tab out of any component.

### Understandable
- **Labels**: Every form input has a visible label (not just placeholder text — placeholders disappear on focus).
- **Error identification**: Errors are described in text, associated with the relevant field, and announced to screen readers.
- **Consistent navigation**: Navigation patterns are consistent across pages. Same action, same location, same behavior.
- **Language**: Set `lang` attribute on `<html>`. Use plain language for UI text.

### Robust
- **Semantic HTML**: Use `<button>` for actions, `<a>` for navigation, `<input>` for data entry. Don't style `<div>` as a button.
- **ARIA correctly**: Only use ARIA when native HTML semantics are insufficient. `role="button"` on a `<div>` is almost always wrong — use `<button>`.
- **Valid HTML**: No duplicate IDs, proper nesting, all required attributes present.

## Responsive Design

### Breakpoints
Use the project's established breakpoints. If none exist, use:
- `sm`: 640px
- `md`: 768px
- `lg`: 1024px
- `xl`: 1280px

### Layout Principles
- **Mobile-first**: Default styles target mobile. Use `min-width` media queries to add complexity for larger screens.
- **Fluid layouts**: Use `flex`, `grid`, relative units (`%`, `rem`, `vw`). Avoid fixed pixel widths for containers.
- **Content readability**: Maximum line length of ~80 characters for body text. Use `max-width` on text containers.
- **No horizontal scroll**: Content must fit within the viewport at 320px minimum width. Test for overflow.
- **Touch-friendly spacing**: Increase padding between interactive elements on mobile. Adjacent tap targets should not overlap.

### Responsive Patterns
- **Stack on mobile, row on desktop**: Use `flex-col` on mobile, `sm:flex-row` on desktop for side-by-side layouts.
- **Collapse secondary content**: Sidebars, detail panels, and supplementary info collapse or hide on mobile.
- **Simplify navigation on mobile**: Use hamburger menus, bottom nav, or simplified header on small screens.
- **Responsive images**: Use `object-fit`, `srcset`, or responsive width classes. Don't serve desktop-sized images to mobile.
- **Responsive typography**: Base font size should be at least 16px on mobile. Scale up moderately for desktop.

## Design Consistency

### Design Tokens
- **Colors**: Use CSS custom properties or Tailwind theme values. Never hardcode hex/rgb values in components.
- **Spacing**: Use the project's spacing scale consistently. Don't mix `p-3` and `p-[13px]`.
- **Typography**: Use the project's font scale. Don't introduce new font sizes, weights, or families.
- **Shadows/Borders**: Use existing elevation/border patterns. New components should match the visual weight of existing ones.
- **Border radius**: Use consistent rounding (the project's `rounded-lg`, not arbitrary pixel values).

### Component Patterns
- **Buttons**: Primary (1 per view), secondary, destructive (red), ghost. Match existing button styles.
- **Cards**: Consistent padding, border, shadow. Same card component for similar content types.
- **Modals/Dialogs**: Consistent overlay, sizing, padding, close behavior (Escape, backdrop click, X button).
- **Loading states**: Skeleton screens or spinners — pick one per context and be consistent.
- **Empty states**: Show a clear message and a call-to-action. Don't show a blank page.
- **Error states**: Inline errors near the problem. Toast notifications for transient success/failure.

### Icons
- Use the project's icon library consistently (e.g., Lucide, Heroicons).
- Don't mix icon libraries in the same project.
- Icons accompanying text should be visually balanced (same size, aligned).
- Interactive icon-only buttons need `aria-label` and `title`.

## Interaction Patterns

### Feedback
- **Immediate**: Button press shows visual change (color, disabled state) instantly.
- **Progress**: Long operations (>1s) show loading indicator. Very long operations (>5s) show progress percentage or status text.
- **Confirmation**: Success/failure feedback within 1s of completion (toast, inline message, state change).
- **Destructive actions**: Always require explicit confirmation (dialog or undo).

### Navigation
- **URL state**: Anything a user might want to bookmark, share, or back-navigate to should be reflected in the URL.
- **Back button**: Browser back should work predictably. Modals and overlays should use the history stack if they represent a "page" the user navigated to.
- **Breadcrumbs**: For hierarchical content deeper than 2 levels.

### Forms
- **Validation**: Validate on submit, show errors inline near each field. Don't clear the form on error.
- **Autofocus**: First input in a form should receive focus when the form appears.
- **Submit on Enter**: Forms should submit when pressing Enter in a text field (standard browser behavior — don't override it).
- **Disabled submit**: Disable the submit button while a submission is in progress to prevent double-submission.

## Performance UX
- **Perceived speed**: Show skeleton screens while loading instead of blank pages. Optimistic UI updates where safe.
- **Virtualization**: Lists with 100+ items should use virtual scrolling.
- **Lazy loading**: Images below the fold should lazy-load. Heavy components should code-split.
- **No layout shift**: Reserve space for images and dynamic content to prevent content jumping (set explicit width/height or aspect-ratio).
