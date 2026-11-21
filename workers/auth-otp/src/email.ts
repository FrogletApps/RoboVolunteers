import { HttpError, type Env } from "./types.ts";

export async function sendOtpEmail(
  env: Env,
  recipientEmail: string,
  otpCode: string,
  ttlMinutes: number
): Promise<void> {
  const senderEmail = env.SENDER_EMAIL?.trim() || "noreply@roboref.app";
  const senderName = env.SENDER_NAME?.trim() || "RoboVolunteers";

  const subject = `${otpCode} is your RoboVolunteers sign-in code`;
  const text = [
    "RoboVolunteers — Sign-In Verification",
    "",
    `Your 6-digit verification code is: ${otpCode}`,
    "",
    `This code expires in ${ttlMinutes} minutes.`,
    "Once verified, your device session will remain signed in automatically.",
    "",
    "If you did not request this code, you can safely ignore this email.",
  ].join("\n");

  const html = `<!DOCTYPE html>
<html lang="en">
<body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; color: #1e293b; max-width: 480px; margin: 0 auto; padding: 24px;">
  <h2 style="color: #15803d; margin-bottom: 8px;">RoboVolunteers</h2>
  <p style="font-size: 14px; color: #475569; margin-top: 0;">UK VEX Robotics Competition Volunteer Management</p>
  <p style="font-size: 15px;">Enter the following 6-digit verification code in the app to sign in:</p>
  <div style="background: #f1f5f9; border: 1px solid #cbd5e1; border-radius: 12px; padding: 18px; text-align: center; margin: 20px 0;">
    <span style="font-family: monospace; font-size: 32px; font-weight: 700; letter-spacing: 6px; color: #0f172a;">${otpCode}</span>
  </div>
  <p style="font-size: 13px; color: #64748b;">This code expires in ${ttlMinutes} minutes. Once signed in, your session will stay remembered on your device.</p>
  <hr style="border: none; border-top: 1px solid #e2e8f0; margin: 20px 0;" />
  <p style="font-size: 12px; color: #94a3b8;">If you didn't request this verification code, you can safely ignore this email.</p>
</body>
</html>`;

  try {
    await env.EMAIL.send({
      to: recipientEmail,
      from: { email: senderEmail, name: senderName },
      subject,
      text,
      html,
    });
  } catch (err) {
    if (err instanceof HttpError) {
      throw err;
    }
    console.error("Failed to send OTP email:", err);
    throw new HttpError(
      502,
      "email_delivery_failed",
      "Unable to send verification email right now. Please try again."
    );
  }
}
