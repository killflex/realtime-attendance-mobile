# App Requirement: Face Recognition Attendance

## Context

This is a Flutter mobile application using FaceNet from MLKit (TFLite) for face recognition. We need to refactor the codebase to follow the base practice and performance wise improvement.

## Visual Style Guidelines (IMPORTANT)

We want to implement the Shadcn UI Flutter—components, theming, and tooling.
Reference: https://flutter-shadcn-ui.mariuti.com/ and https://pub.dev/packages/shadcn_flutter.

**Flutter Implementation Rules:**

1.  **Radius:** Use `BorderRadius.circular(8)` for cards, inputs, and buttons.
2.  **Colors:**
    - Background: White or very light gray (`Colors.grey[50]`).
    - Borders: Thin, subtle borders (`Colors.grey[300]`).
    - Primary: Deep Black (`Color(0xFF09090b)`) or Slate 900.
    - Text: Inter or Roboto font.
3.  **Inputs:** Use `InputDecoration` with `OutlineInputBorder`. When focused, ring/border should be black.
4.  **Animations:** Use `AnimatedSwitcher` or `PageView` for smooth transitions between form steps.

## Functional Requirements

The registration process must be split into two steps:

### Step 1: User Data Form

Before showing the camera, display a clean form with:

1.  **Status:** Dropdown ['Dosen', 'Tendik', 'Mahasiswa'].
2.  **Unit Kerja (Cascading Logic):**
    - If UPA selected -> Dropdown ['Bahasa', 'Kewirausahaan', ...].
    - If Lembaga selected -> Dropdown ['LPPM', 'LPMPP'].
    - If Fakultas selected -> Dropdown ['Ilmu Komputer', ...].
3.  **Identity:** Text Field label changes dynamically (NIP vs NPM) based on Status.
4.  **Contact:** Phone (Numeric) and Email (Validation required).

_Action:_ "Next" button validates form -> Moves to Step 2.

### Step 2: Face Capture

1.  Show Camera Preview.
2.  Overlay "Caution" message (Remove glasses, good lighting) styled as a Shadcn Alert Dialog.
3.  Guide user to capture 5 angles (Front, Right, Left, Up, Down).
