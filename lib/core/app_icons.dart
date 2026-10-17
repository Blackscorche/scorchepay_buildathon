import 'package:flutter/material.dart';

/// Semantic icon set for ScorchePay, mapped onto Flutter's built-in
/// Material Symbols (rounded variants) so the whole app ships with zero
/// icon-font dependencies. Keeping this as one lookup table means every
/// screen references *meaning* ("send", "escrow") rather than a raw
/// IconData, so the visual language stays consistent if we ever swap the
/// underlying icon pack.
class AppIcons {
  AppIcons._();

  static const IconData home = Icons.home_rounded;
  static const IconData homeOutline = Icons.home_outlined;
  static const IconData wallet = Icons.account_balance_wallet_rounded;
  static const IconData walletOutline = Icons.account_balance_wallet_outlined;
  static const IconData bolt = Icons.bolt_rounded;
  static const IconData coins = Icons.monetization_on_outlined;
  static const IconData bitcoin = Icons.currency_bitcoin_rounded;
  static const IconData grid = Icons.grid_view_rounded;
  static const IconData bell = Icons.notifications_none_rounded;
  static const IconData user = Icons.person_outline_rounded;
  static const IconData eye = Icons.visibility_outlined;
  static const IconData eyeOff = Icons.visibility_off_outlined;
  static const IconData chevronRight = Icons.chevron_right_rounded;
  static const IconData chevronLeft = Icons.chevron_left_rounded;
  static const IconData chevronDown = Icons.keyboard_arrow_down_rounded;
  static const IconData send = Icons.north_east_rounded;
  static const IconData receive = Icons.south_west_rounded;
  static const IconData bill = Icons.receipt_long_outlined;
  static const IconData shield = Icons.shield_outlined;
  static const IconData shieldCheck = Icons.verified_user_outlined;
  static const IconData target = Icons.track_changes_rounded;
  static const IconData bag = Icons.storefront_outlined;
  static const IconData globe = Icons.public_rounded;
  static const IconData trophy = Icons.emoji_events_outlined;
  static const IconData users = Icons.groups_outlined;
  static const IconData receipt = Icons.receipt_outlined;
  static const IconData chartLine = Icons.show_chart_rounded;
  static const IconData chartBar = Icons.bar_chart_rounded;
  static const IconData sparkle = Icons.auto_awesome_rounded;
  static const IconData lock = Icons.lock_outline_rounded;
  static const IconData gear = Icons.settings_outlined;
  static const IconData briefcase = Icons.work_outline_rounded;
  static const IconData code = Icons.code_rounded;
  static const IconData key = Icons.vpn_key_outlined;
  static const IconData copy = Icons.content_copy_rounded;
  static const IconData share = Icons.ios_share_rounded;
  static const IconData search = Icons.search_rounded;
  static const IconData calendar = Icons.calendar_today_outlined;
  static const IconData repeat = Icons.swap_horiz_rounded;
  static const IconData plus = Icons.add_rounded;
  static const IconData minus = Icons.remove_rounded;
  static const IconData arrowUpRight = Icons.trending_up_rounded;
  static const IconData arrowDownRight = Icons.trending_down_rounded;
  static const IconData check = Icons.check_rounded;
  static const IconData qr = Icons.qr_code_rounded;
  static const IconData link = Icons.link_rounded;
  static const IconData fingerprint = Icons.fingerprint_rounded;
  static const IconData monitor = Icons.devices_other_outlined;
  static const IconData mail = Icons.mail_outline_rounded;
  static const IconData package = Icons.inventory_2_outlined;
  static const IconData building = Icons.account_balance_outlined;
  static const IconData filter = Icons.filter_list_rounded;
  static const IconData download = Icons.file_download_outlined;
  static const IconData book = Icons.menu_book_outlined;
  static const IconData webhook = Icons.hub_outlined;
  static const IconData idCard = Icons.badge_outlined;
  static const IconData flame = Icons.local_fire_department_rounded;
  static const IconData phone = Icons.phone_iphone_rounded;
  static const IconData emailOutline = Icons.mail_outline_rounded;
  static const IconData faceId = Icons.face_retouching_natural_rounded;
  static const IconData arrowBack = Icons.arrow_back_ios_new_rounded;
  static const IconData backspace = Icons.backspace_outlined;
  static const IconData warning = Icons.error_outline_rounded;
  static const IconData tv = Icons.live_tv_outlined;
  static const IconData wifi = Icons.wifi_rounded;
  static const IconData giftCard = Icons.card_giftcard_outlined;
  static const IconData education = Icons.school_outlined;
  static const IconData bet = Icons.casino_outlined;
  static const IconData camera = Icons.camera_alt_rounded;
  static const IconData image = Icons.image_outlined;
  static const IconData trash = Icons.delete_outline_rounded;
  static const IconData close = Icons.close_rounded;
  static const IconData sun = Icons.light_mode_rounded;
  static const IconData moon = Icons.dark_mode_rounded;
  static const IconData contrast = Icons.contrast_rounded;
  static const IconData logout = Icons.logout_rounded;
  static const IconData refresh = Icons.refresh;
}
