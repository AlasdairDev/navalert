import 'package:flutter/material.dart';

import 'theme.dart';

/// Single source of truth for the Terms & Conditions / Privacy Policy copy
/// and the dialog that displays it — shared by Settings (Figure 33) and the
/// onboarding tutorial's final page, so the two never drift out of sync.
class LegalText {
  const LegalText._();

  static const _groupName = 'Group 11 BSIT 4-4';
  static const _developers =
      'Keith Justine S. Ababao, Kyla J. Barbin, Roje Alasdair T. Evangelista, '
      'and Pauline R. Lacanilao';
  static const _contactEmail = 'keithjustine57@gmail.com';

  static const terms = '''
Effective Date: August 26, 2026

1. Acceptance of Terms

These Terms and Conditions ("Terms") govern your access to and use of the NavAlert mobile application ("NavAlert," "the App"), developed by $_groupName as part of a capstone project at the Polytechnic University of the Philippines. By downloading, installing, or using NavAlert, you agree to be bound by these Terms and by our Privacy Policy. If you do not agree, do not use the App.

2. Description of Service

NavAlert is a commuter-assistance application for commuters riding public utility vehicles (PUVs) in Metro Manila. It provides a built-in commute guide, a multi-stage destination alarm that adjusts to real-time GPS speed, an SOS button that shares your GPS location with pre-saved emergency contacts by SMS, and a fake call feature intended to help users appear occupied in uncomfortable situations.

3. Eligibility and Responsible Use

• You must be able to form a legally binding agreement to use NavAlert. Users under 18 should use the App only with the involvement and consent of a parent or guardian.
• You are responsible for keeping your emergency contact details accurate and up to date, since inaccurate details may prevent alerts from reaching the intended person.

4. Important Safety Disclaimer

NavAlert's alarm, SOS, and fake call features are intended as convenience and personal-safety aids, not as a replacement for official emergency services. In an actual emergency, you should still contact the Philippine National Police, barangay authorities, or dial the national emergency hotline (911) directly whenever possible.

• GPS accuracy may be reduced near tall buildings, in tunnels, or in areas with limited satellite visibility, which can delay or affect the precision of alarms and SOS location data.
• SOS and alarm notifications depend on your device having a working SIM card, sufficient signal, and/or an internet connection; delivery is not guaranteed and may be delayed or fail entirely due to network conditions outside our control.
• The fake call feature is a simulated call for personal comfort and does not connect to any real person, emergency service, or law enforcement agency.
• You are solely responsible for deciding when and how to use the SOS and fake call features, and for verifying that your emergency contacts are aware they may receive such alerts.

5. Acceptable Use

You agree not to:

• Use the SOS feature to send false alarms or to harass, prank, or deceive your listed emergency contacts.
• Attempt to reverse-engineer, decompile, or interfere with the App's normal operation or security features.
• Use NavAlert for any unlawful purpose or in a way that infringes the rights of others.

6. Location and Device Permissions

NavAlert requires access to your device's location services, notifications, and SMS-sending capability to deliver its core features. You may revoke these permissions at any time through your device settings, but doing so may disable or degrade key features such as destination alarms and SOS location sharing.

7. Intellectual Property

The NavAlert application, including its design, source code, logos, and documentation, is the intellectual property of $_groupName and Polytechnic University of the Philippines, except for third-party components (such as map data, APIs, and open-source libraries) which remain the property of their respective owners and are used under their applicable licenses.

8. Third-Party Services

NavAlert relies on third-party services: OpenStreetMap for map tiles, the OpenStreetMap Nominatim service for place search, the OSRM service for road-following route geometry, and your mobile network's SMS gateway for delivering SOS messages. NavAlert can also hand off to the Google Maps app installed on your device for return-route assistance, which is then governed by Google's own terms. Your use of NavAlert is also subject to the applicable terms and privacy policies of these third-party providers, over which we have no control.

9. Disclaimer of Warranties

NavAlert is provided "as is" and "as available," as an academic capstone project, without warranties of any kind, whether express or implied, including but not limited to warranties of merchantability, fitness for a particular purpose, accuracy, or non-infringement. We do not warrant that the App will be uninterrupted, error-free, or that alarms and alerts will always trigger correctly or on time.

10. Limitation of Liability

To the fullest extent permitted by law, $_groupName, its student developers, advisers, and Polytechnic University of the Philippines shall not be liable for any indirect, incidental, special, or consequential damages, or for any missed stops, delayed or failed alerts, missed SOS notifications, or personal injury or loss arising from reliance on the App, including situations caused by GPS inaccuracy, network outages, or third-party service failures.

11. Termination

We may suspend or discontinue NavAlert, in whole or in part, at any time, including upon conclusion of the capstone project, without liability. You may stop using NavAlert and clear or delete your locally stored data at any time.

12. Governing Law

These Terms are governed by the laws of the Republic of the Philippines. Any disputes arising from the use of NavAlert shall be subject to the exclusive jurisdiction of the appropriate courts in the Philippines.

13. Changes to These Terms

We may revise these Terms from time to time. Continued use of NavAlert after changes take effect constitutes acceptance of the revised Terms. Material changes will be indicated by an updated "Effective Date."

14. Contact Us

Questions about these Terms may be directed to:

$_groupName - NavAlert Capstone Team
$_developers
Polytechnic University of the Philippines
Email: $_contactEmail''';

  static const privacy = '''
Effective Date: August 26, 2026

1. Introduction

NavAlert ("NavAlert," "the App," "we," "us," or "our") is a mobile application developed by $_groupName, a student capstone project of the Polytechnic University of the Philippines, designed to help commuters using public utility vehicles (PUVs) in Metro Manila avoid missing their stops and stay safe while traveling. This Privacy Policy explains what information NavAlert collects, how it is used and stored, who it may be shared with, and the choices and rights available to users.

By downloading, installing, or using NavAlert, you agree to the collection and use of information as described in this Privacy Policy. If you do not agree, please do not use the App.

2. Information We Collect

2.1 Information You Provide

• Emergency contact details - the names and phone numbers of up to three contacts you designate to receive SOS alerts.
• Fake call configuration - the caller name and schedule preferences you set up for the simulated call feature.
• Trip preferences - your chosen destination stop and preferred route.
• Voice recordings - any audio you record inside the App to use as a custom fake-call voice. Recordings are saved on your device and are never uploaded.

2.2 Information Collected Automatically

• Real-time GPS location - used to detect your speed and proximity to your destination so the multi-stage alarm can trigger at the right time, and to determine your coordinates when you activate the SOS button.
• Device and sensor data - general device information (such as OS version and device model) and motion/speed data derived from GPS, used to power the adaptive alarm timing.
• Alert and usage logs - records of triggered alarms, SOS activations, and fake call activations, stored primarily on your device to support offline functionality and troubleshooting.
• Network status - whether your device has an active internet or SMS connection, used to decide whether an SOS can be delivered and to tell you plainly when it cannot.

2.3 Information We Do Not Intentionally Collect

NavAlert does not access your camera, photos, contacts list (beyond the emergency contacts you manually enter), or browsing history, and does not request permissions unrelated to its core location, notification, recording, and SMS-based safety features. Microphone access is used only while you are actively recording a custom fake-call voice, never in the background and never during a trip.

3. How We Use Your Information

• To trigger destination alarms at the correct point in your trip based on real-time GPS speed and location.
• To send your GPS coordinates by SMS to your designated emergency contacts when you activate the SOS button.
• To operate the fake call feature according to the settings you configure.
• To plan routes, by combining the public transport timetable data bundled with the App against map data from OpenStreetMap and the Nominatim and OSRM services.
• To diagnose errors, maintain offline alarm reliability, and improve the App based on aggregated, de-identified usage patterns.

4. How We Store and Protect Your Information

NavAlert does not require you to create an account, and the development team operates no servers. Emergency contacts, fake call settings, trip preferences, voice recordings, and alert logs are stored only on your device, in an encrypted SQLite database, so that core safety features keep working without an internet connection. Backups are files you export yourself and save wherever you choose on your own device; no copy is ever sent to us.

We apply reasonable technical safeguards, including encryption of the on-device database and the use of encrypted (HTTPS) connections to the map, search, and routing services the App contacts. No method of electronic storage or transmission is completely secure, and we cannot guarantee absolute security.

5. Sharing and Disclosure of Information

We do not sell your personal information. We share information only in the following circumstances:

• With your designated emergency contacts, solely for the purpose of delivering SOS alerts containing your GPS location.
• With the mapping, place-search, and routing services the App contacts to draw the map and plan a trip (OpenStreetMap, Nominatim, and OSRM), which necessarily receive the locations being looked up, and with the mobile network carrier that carries your SOS message.
• If required by law, legal process, or a lawful government request, or to protect the rights, safety, or property of users or the public.
• With the capstone research team and academic advisers, in aggregated or de-identified form, for evaluation of the project.

6. Your Rights Under the Data Privacy Act

As a user based in the Philippines, you have rights under the Data Privacy Act of 2012 (Republic Act No. 10173) and its Implementing Rules and Regulations, including the right to be informed, the right to access your personal data, the right to correct inaccurate data, the right to object to processing, the right to data portability, and the right to file a complaint with the National Privacy Commission (NPC).

You may exercise these rights by contacting us using the details in Section 11. You may delete individual emergency contacts, voice recordings, favorites, and trip records at any time from within the App. To remove everything at once, use your device's Settings > Apps > NavAlert > Storage > Clear storage, or uninstall the App.

7. Data Retention

Emergency contact details, fake call settings, and trip preferences are retained on your device for as long as the App remains installed and you have not cleared them. Locally stored alert logs remain on your device until you clear them or uninstall the App. Because NavAlert operates no servers, clearing your data or uninstalling the App removes it completely - there are no server-side copies for us to delete. Any backup file you exported yourself stays where you saved it until you delete it.

8. Location Permissions

NavAlert requires location (GPS) permission to function. You may disable location access at any time through your device settings; however, doing so will prevent destination alarms, speed-based alerts, and GPS-based SOS location sharing from working correctly. Some features (such as fixed-distance or offline alarms) may operate with reduced accuracy without continuous GPS access.

9. Children's Privacy

NavAlert is not directed at children under 13, and we do not knowingly collect personal information from children under 13. If you believe a child has provided us with personal information, please contact us so we can remove it.

10. Changes to This Privacy Policy

We may update this Privacy Policy from time to time to reflect changes in the App's features or applicable law. We will indicate the "Effective Date" at the top of this document and, for material changes, provide notice within the App or through other reasonable means.

11. Contact Us

If you have questions, concerns, or requests regarding this Privacy Policy or your personal data, please contact:

$_groupName - NavAlert Capstone Team
$_developers
Polytechnic University of the Philippines
Email: $_contactEmail''';

  /// A numbered section heading — "1. Acceptance of Terms" or the
  /// subsection form "2.1 Information You Provide" — bolded and colored so
  /// the long legal text has visible structure while scrolling.
  static final _headingPattern = RegExp(r'^\d+(\.\d+)?\.?\s');

  static void show(BuildContext context, String text) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('NavAlert'),
        content: SizedBox(
          width: double.maxFinite,
          height: 420,
          child: SingleChildScrollView(
            child: Text.rich(
              TextSpan(
                children: [
                  for (final line in text.split('\n'))
                    TextSpan(
                      text: '$line\n',
                      style: _headingPattern.hasMatch(line)
                          ? const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: NavAlertColors.accent)
                          : const TextStyle(fontSize: 13),
                    ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close')),
        ],
      ),
    );
  }
}
