//
//  AuthButtons.swift
//  snoozestack-swift
//
//  Drop-in provider sign-in buttons, so every app pairing
//  `identity.signInWithIdToken` with a login screen doesn't re-draw them.
//  These are STYLING shortcuts only — each takes the app's own handlers and
//  performs no auth itself.
//
//  SnoozestackAppleSignInButton wraps Apple's `SignInWithAppleButton` (the
//  control App Review expects) at a 50pt/12pt-radius geometry; pass a style
//  to override the white default. SnoozestackGoogleSignInButton renders
//  Google's light-theme treatment from their branding guidelines — white
//  fill, #747775 hairline, #1F1F1F label — with the real four-colour "G"
//  (SnoozestackGoogleLogo) drawn in Canvas from the official logo's paths,
//  vector-crisp at any size with no bundled asset.
//

import AuthenticationServices
import SwiftUI

/// Sign in with Apple, sized to pair with ``SnoozestackGoogleSignInButton``.
public struct SnoozestackAppleSignInButton: View {
    private let label: SignInWithAppleButton.Label
    private let style: SignInWithAppleButton.Style
    private let onRequest: (ASAuthorizationAppleIDRequest) -> Void
    private let onCompletion: (Result<ASAuthorization, Error>) -> Void

    public init(
        _ label: SignInWithAppleButton.Label = .signIn,
        style: SignInWithAppleButton.Style = .white,
        onRequest: @escaping (ASAuthorizationAppleIDRequest) -> Void,
        onCompletion: @escaping (Result<ASAuthorization, Error>) -> Void
    ) {
        self.label = label
        self.style = style
        self.onRequest = onRequest
        self.onCompletion = onCompletion
    }

    public var body: some View {
        SignInWithAppleButton(label, onRequest: onRequest, onCompletion: onCompletion)
            .signInWithAppleButtonStyle(style)
            .frame(height: 50)
            .cornerRadius(12)
    }
}

/// Sign in with Google, in Google's own light-theme treatment.
public struct SnoozestackGoogleSignInButton: View {
    private let title: String
    private let action: () -> Void

    /// Google's light-button palette, quoted from their branding guidelines
    /// rather than any app theme — the button has to look like Google's.
    private static let fill = Color.white
    private static let stroke = Color(red: 0x74 / 255, green: 0x77 / 255, blue: 0x75 / 255)
    private static let label = Color(red: 0x1F / 255, green: 0x1F / 255, blue: 0x1F / 255)

    public init(title: String = "Sign in with Google", action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SnoozestackGoogleLogo()
                    .frame(width: 20, height: 20)
                Text(title)
                    .font(.system(size: 17, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
        }
        .foregroundColor(Self.label)
        .background(Self.fill)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Self.stroke, lineWidth: 1)
        )
    }
}

/// Google's four-colour "G", drawn from the official logo's paths. Their brand
/// guidelines require the real mark on a sign-in button — an approximated
/// glyph is both inaccurate and non-compliant.
public struct SnoozestackGoogleLogo: View {
    public init() {}

    public var body: some View {
        Canvas { context, size in
            let scaleX = size.width / 24
            let scaleY = size.height / 24

            // Blue
            context.fill(
                Path { path in
                    path.move(to: CGPoint(x: 22.56 * scaleX, y: 12.25 * scaleY))
                    path.addCurve(
                        to: CGPoint(x: 22.36 * scaleX, y: 10 * scaleY),
                        control1: CGPoint(x: 22.56 * scaleX, y: 11.47 * scaleY),
                        control2: CGPoint(x: 22.49 * scaleX, y: 10.72 * scaleY)
                    )
                    path.addLine(to: CGPoint(x: 12 * scaleX, y: 10 * scaleY))
                    path.addLine(to: CGPoint(x: 12 * scaleX, y: 14.26 * scaleY))
                    path.addLine(to: CGPoint(x: 17.92 * scaleX, y: 14.26 * scaleY))
                    path.addCurve(
                        to: CGPoint(x: 15.71 * scaleX, y: 17.57 * scaleY),
                        control1: CGPoint(x: 17.66 * scaleX, y: 15.63 * scaleY),
                        control2: CGPoint(x: 16.88 * scaleX, y: 16.79 * scaleY)
                    )
                    path.addLine(to: CGPoint(x: 15.71 * scaleX, y: 20.34 * scaleY))
                    path.addLine(to: CGPoint(x: 19.28 * scaleX, y: 20.34 * scaleY))
                    path.addCurve(
                        to: CGPoint(x: 22.56 * scaleX, y: 12.25 * scaleY),
                        control1: CGPoint(x: 21.36 * scaleX, y: 18.42 * scaleY),
                        control2: CGPoint(x: 22.56 * scaleX, y: 15.6 * scaleY)
                    )
                    path.closeSubpath()
                },
                with: .color(Color(red: 66 / 255, green: 133 / 255, blue: 244 / 255))
            )

            // Green
            context.fill(
                Path { path in
                    path.move(to: CGPoint(x: 12 * scaleX, y: 23 * scaleY))
                    path.addCurve(
                        to: CGPoint(x: 19.28 * scaleX, y: 20.34 * scaleY),
                        control1: CGPoint(x: 14.97 * scaleX, y: 23 * scaleY),
                        control2: CGPoint(x: 17.46 * scaleX, y: 22.02 * scaleY)
                    )
                    path.addLine(to: CGPoint(x: 15.71 * scaleX, y: 17.57 * scaleY))
                    path.addCurve(
                        to: CGPoint(x: 12 * scaleX, y: 18.63 * scaleY),
                        control1: CGPoint(x: 14.73 * scaleX, y: 18.23 * scaleY),
                        control2: CGPoint(x: 13.48 * scaleX, y: 18.63 * scaleY)
                    )
                    path.addCurve(
                        to: CGPoint(x: 5.84 * scaleX, y: 14.1 * scaleY),
                        control1: CGPoint(x: 9.14 * scaleX, y: 18.63 * scaleY),
                        control2: CGPoint(x: 6.71 * scaleX, y: 16.7 * scaleY)
                    )
                    path.addLine(to: CGPoint(x: 2.18 * scaleX, y: 16.94 * scaleY))
                    path.addCurve(
                        to: CGPoint(x: 12 * scaleX, y: 23 * scaleY),
                        control1: CGPoint(x: 3.99 * scaleX, y: 20.53 * scaleY),
                        control2: CGPoint(x: 7.7 * scaleX, y: 23 * scaleY)
                    )
                    path.closeSubpath()
                },
                with: .color(Color(red: 52 / 255, green: 168 / 255, blue: 83 / 255))
            )

            // Yellow
            context.fill(
                Path { path in
                    path.move(to: CGPoint(x: 5.84 * scaleX, y: 14.09 * scaleY))
                    path.addCurve(
                        to: CGPoint(x: 5.49 * scaleX, y: 12 * scaleY),
                        control1: CGPoint(x: 5.62 * scaleX, y: 13.43 * scaleY),
                        control2: CGPoint(x: 5.49 * scaleX, y: 12.73 * scaleY)
                    )
                    path.addCurve(
                        to: CGPoint(x: 5.84 * scaleX, y: 9.91 * scaleY),
                        control1: CGPoint(x: 5.49 * scaleX, y: 11.27 * scaleY),
                        control2: CGPoint(x: 5.62 * scaleX, y: 10.57 * scaleY)
                    )
                    path.addLine(to: CGPoint(x: 5.84 * scaleX, y: 7.07 * scaleY))
                    path.addLine(to: CGPoint(x: 2.18 * scaleX, y: 7.07 * scaleY))
                    path.addCurve(
                        to: CGPoint(x: 1 * scaleX, y: 12 * scaleY),
                        control1: CGPoint(x: 1.43 * scaleX, y: 8.55 * scaleY),
                        control2: CGPoint(x: 1 * scaleX, y: 10.22 * scaleY)
                    )
                    path.addCurve(
                        to: CGPoint(x: 2.18 * scaleX, y: 16.93 * scaleY),
                        control1: CGPoint(x: 1 * scaleX, y: 13.78 * scaleY),
                        control2: CGPoint(x: 1.43 * scaleX, y: 15.45 * scaleY)
                    )
                    path.addLine(to: CGPoint(x: 5.03 * scaleX, y: 14.71 * scaleY))
                    path.addLine(to: CGPoint(x: 5.84 * scaleX, y: 14.09 * scaleY))
                    path.closeSubpath()
                },
                with: .color(Color(red: 251 / 255, green: 188 / 255, blue: 5 / 255))
            )

            // Red
            context.fill(
                Path { path in
                    path.move(to: CGPoint(x: 12 * scaleX, y: 5.38 * scaleY))
                    path.addCurve(
                        to: CGPoint(x: 16.21 * scaleX, y: 7.02 * scaleY),
                        control1: CGPoint(x: 13.62 * scaleX, y: 5.38 * scaleY),
                        control2: CGPoint(x: 15.06 * scaleX, y: 5.94 * scaleY)
                    )
                    path.addLine(to: CGPoint(x: 19.36 * scaleX, y: 3.87 * scaleY))
                    path.addCurve(
                        to: CGPoint(x: 12 * scaleX, y: 1 * scaleY),
                        control1: CGPoint(x: 17.45 * scaleX, y: 2.09 * scaleY),
                        control2: CGPoint(x: 14.97 * scaleX, y: 1 * scaleY)
                    )
                    path.addCurve(
                        to: CGPoint(x: 2.18 * scaleX, y: 7.07 * scaleY),
                        control1: CGPoint(x: 7.7 * scaleX, y: 1 * scaleY),
                        control2: CGPoint(x: 3.99 * scaleX, y: 3.47 * scaleY)
                    )
                    path.addLine(to: CGPoint(x: 5.84 * scaleX, y: 9.91 * scaleY))
                    path.addCurve(
                        to: CGPoint(x: 12 * scaleX, y: 5.38 * scaleY),
                        control1: CGPoint(x: 6.71 * scaleX, y: 7.31 * scaleY),
                        control2: CGPoint(x: 9.14 * scaleX, y: 5.38 * scaleY)
                    )
                    path.closeSubpath()
                },
                with: .color(Color(red: 234 / 255, green: 67 / 255, blue: 53 / 255))
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
