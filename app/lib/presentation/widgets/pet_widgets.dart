import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_colors.dart';
import '../../core/strings.dart';
import '../../domain/models.dart';
import '../../domain/pet.dart';
import '../pet_controller.dart';

/// A pet event inside the conversation timeline. Care actions are content: they
/// show who grew the companion and when, and open the shared pet card on tap.
class PetEventChip extends StatelessWidget {
  const PetEventChip({
    super.key,
    required this.message,
    required this.mine,
    required this.strings,
    this.highlight = false,
    this.onTap,
    this.onLongPress,
  });

  final Message message;
  final bool mine;
  final AppStrings strings;
  final bool highlight;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final rawState = message.meta['petState'];
    final pet = rawState is Map
        ? PetState.fromJson(rawState.cast<String, dynamic>())
        : null;
    final action = message.meta['pet'] as String? ?? 'care';
    final species = pet?.species ?? PetSpecies.coral;
    final name = pet?.name ?? strings.get('petDefaultName');
    final label = switch (action) {
      'adopt' =>
        strings
            .get('petEventAdopt')
            .replaceAll('{name}', name)
            .replaceAll('{species}', strings.get(species.nameKey)),
      'rename' => strings.get('petEventRename').replaceAll('{name}', name),
      _ =>
        strings
            .get('petEventCare')
            .replaceAll(
              '{action}',
              strings.get(
                petActionKey(
                  petActionFromId(action) ?? PetAction.care,
                  species,
                ),
              ),
            )
            .replaceAll('{name}', name),
    };
    final accent = mine ? palette.accentSoft : palette.accent;
    return Align(
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 6),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Container(
            padding: const EdgeInsets.fromLTRB(8, 5, 14, 5),
            decoration: BoxDecoration(
              color: palette.surface.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: highlight
                    ? palette.halo.withValues(alpha: 0.8)
                    : palette.divider,
                width: highlight ? 1.5 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PetPortrait(
                  pet:
                      pet ??
                      PetState.adopt(
                        chatId: message.chatId,
                        species: species,
                        name: name,
                        adopterId: message.senderId,
                      ),
                  size: 30,
                  animate: false,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: 12.5,
                      height: 1.2,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.eco_rounded, size: 13, color: accent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The pet card above the composer: a living portrait, growth stage,
/// wellbeing and the four care actions. Shared state is synchronized through
/// encrypted server operations.
class PetPanel extends ConsumerStatefulWidget {
  const PetPanel({
    super.key,
    required this.chatId,
    required this.strings,
    this.expandToken = 0,
    this.personal = false,
  });

  final String chatId;
  final AppStrings strings;
  final bool personal;

  /// Bumped by the chat screen when a pet event in the timeline is tapped, so
  /// the card opens instead of staying folded.
  final int expandToken;

  @override
  ConsumerState<PetPanel> createState() => _PetPanelState();
}

class _PetPanelState extends ConsumerState<PetPanel> {
  bool _expanded = false;
  Timer? _clock;
  int _reaction = 0;
  ProviderContainer? _container;

  // Adoption form.
  bool _animal = false;
  PetSpecies _species = PetSpecies.coral;
  final _name = TextEditingController();

  @override
  void initState() {
    super.initState();
    _expanded = widget.personal;
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _expanded) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container ??= ProviderScope.containerOf(context);
  }

  @override
  void didUpdateWidget(covariant PetPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expandToken != oldWidget.expandToken) {
      setState(() => _expanded = true);
    }
  }

  @override
  void dispose() {
    _clock?.cancel();
    _name.dispose();
    _container?.invalidate(petProvider(widget.chatId));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final state = ref.watch(petProvider(widget.chatId));
    final record = state.record;
    final pet = state.pet;
    final accent = palette.accent;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 6),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            palette.surface.withValues(alpha: 0.92),
            Color.lerp(palette.surface, accent, 0.10)!,
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: palette.divider),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.10),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
              child: Row(
                children: [
                  if (pet != null)
                    PetPortrait(
                      pet: pet,
                      size: 42,
                      animate: _expanded,
                      reaction: _reaction,
                    )
                  else
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: accent.withValues(alpha: 0.14),
                      ),
                      child: Icon(Icons.eco_rounded, color: accent, size: 21),
                    ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                pet?.name ??
                                    (record?.isPending == true
                                        ? widget.strings.get('petInviteTitle')
                                        : widget.personal
                                        ? widget.strings.get('petPersonalTitle')
                                        : widget.strings.get('petStartTitle')),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: palette.textPrimary,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (pet != null) ...[
                              const SizedBox(width: 6),
                              _Pill(
                                label: widget.strings.get(
                                  petStageKey(pet.stage, pet.species),
                                ),
                                color: accent,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          pet == null
                              ? record?.isPending == true
                                    ? widget.strings.get('petWaiting')
                                    : widget.personal
                                    ? widget.strings.get('petPersonalHint')
                                    : widget.strings.get('petStartHint')
                              : '${widget.strings.get('petLevel')} ${pet.level}'
                                    ' · ${_wellbeingLabel(pet)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.textMuted,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (pet != null && _expanded)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: widget.strings.get('petRename'),
                      onPressed: state.busy ? null : () => _rename(pet),
                      icon: Icon(
                        Icons.edit_outlined,
                        size: 17,
                        color: palette.textMuted,
                      ),
                    ),
                  if (record != null && _expanded)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: widget.strings.get('petRelease'),
                      onPressed: state.busy ? null : _release,
                      icon: Icon(
                        Icons.close_rounded,
                        size: 17,
                        color: palette.textMuted,
                      ),
                    ),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.keyboard_arrow_up_rounded,
                    color: palette.textMuted,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            SizedBox(
              height: math.min(344, MediaQuery.sizeOf(context).height * 0.42),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: record?.isPending == true
                    ? _InviteContent(
                        strings: widget.strings,
                        busy: state.busy,
                        invited: record!.membershipState == 'pending',
                        onAccept: () => ref
                            .read(petProvider(widget.chatId).notifier)
                            .accept(),
                        onDecline: () => ref
                            .read(petProvider(widget.chatId).notifier)
                            .decline(),
                      )
                    : pet == null
                    ? _AdoptForm(
                        strings: widget.strings,
                        animal: _animal,
                        species: _species,
                        name: _name,
                        busy: state.busy,
                        actionLabel: widget.strings.get(
                          widget.personal ? 'petAdopt' : 'petInvite',
                        ),
                        onKind: (animal) => setState(() {
                          _animal = animal;
                          _species = animal
                              ? PetSpecies.turtle
                              : PetSpecies.coral;
                        }),
                        onSpecies: (species) =>
                            setState(() => _species = species),
                        onAdopt: () => _adopt(),
                      )
                    : _CareContent(
                        pet: pet,
                        strings: widget.strings,
                        reaction: _reaction,
                        busy: state.busy,
                        onAction: _care,
                      ),
              ),
            ),
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                state.error!,
                style: TextStyle(color: palette.coral, fontSize: 11.5),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _release() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.palette.surface,
        title: Text(widget.strings.get('petRelease')),
        content: Text(widget.strings.get('petReleaseConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(widget.strings.get('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(widget.strings.get('petRelease')),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(petProvider(widget.chatId).notifier).release();
    }
  }

  String _wellbeingLabel(PetState pet) {
    if (pet.isSad) return widget.strings.get('petMoodSad');
    if (pet.isHappy) return widget.strings.get('petMoodHappy');
    return widget.strings.get('petMoodOkay');
  }

  Future<void> _adopt() async {
    final name = _name.text.trim();
    await ref
        .read(petProvider(widget.chatId).notifier)
        .adopt(
          _species,
          name.isEmpty ? widget.strings.get(_species.nameKey) : name,
        );
    if (!mounted) return;
    setState(() => _reaction++);
    _name.clear();
  }

  Future<void> _care(PetAction action) async {
    await ref.read(petProvider(widget.chatId).notifier).care(action);
    if (mounted) setState(() => _reaction++);
  }

  Future<void> _rename(PetState pet) async {
    final controller = TextEditingController(text: pet.name);
    final palette = context.palette;
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: palette.surface,
        title: Text(widget.strings.get('petRename')),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 24,
          decoration: InputDecoration(labelText: widget.strings.get('petName')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(widget.strings.get('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(widget.strings.get('save')),
          ),
        ],
      ),
    );
    final name = controller.text.trim();
    controller.dispose();
    if (saved != true || name.isEmpty) return;
    await ref.read(petProvider(widget.chatId).notifier).rename(name);
  }
}

class _InviteContent extends StatelessWidget {
  const _InviteContent({
    required this.strings,
    required this.busy,
    required this.invited,
    required this.onAccept,
    required this.onDecline,
  });

  final AppStrings strings;
  final bool busy;
  final bool invited;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        Icon(Icons.mark_email_unread_rounded, size: 34, color: palette.accent),
        const SizedBox(height: 10),
        Text(
          strings.get(invited ? 'petInviteHint' : 'petInviteSent'),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: palette.textPrimary,
            fontSize: 13,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 14),
        if (invited)
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: busy ? null : onDecline,
                  child: Text(strings.get('petDecline')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: busy ? null : onAccept,
                  child: Text(strings.get('petAccept')),
                ),
              ),
            ],
          )
        else
          LinearProgressIndicator(
            minHeight: 2,
            backgroundColor: palette.divider,
            valueColor: AlwaysStoppedAnimation(palette.accent),
          ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: color.withValues(alpha: 0.4)),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: color,
        fontSize: 9.5,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _CareContent extends StatelessWidget {
  const _CareContent({
    required this.pet,
    required this.strings,
    required this.reaction,
    required this.onAction,
    this.busy = false,
  });

  final PetState pet;
  final AppStrings strings;
  final int reaction;
  final ValueChanged<PetAction> onAction;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final now = DateTime.now();
    final caretakers = pet.caretakers.length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 132,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    gradient: RadialGradient(
                      colors: [
                        palette.accent.withValues(alpha: 0.20),
                        palette.surface.withValues(alpha: 0.0),
                      ],
                      radius: 0.9,
                    ),
                  ),
                ),
              ),
              PetPortrait(
                pet: pet,
                size: 124,
                animate: true,
                reaction: reaction,
              ),
              Positioned(
                top: 6,
                left: 10,
                child: Row(
                  children: [
                    Icon(
                      Icons.groups_rounded,
                      size: 13,
                      color: palette.textMuted,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      strings
                          .get('petGrowingTogether')
                          .replaceAll('{count}', '$caretakers'),
                      style: TextStyle(
                        color: palette.textMuted,
                        fontSize: 10.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                strings.get(petStageKey(pet.stage, pet.species)),
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              pet.stage == PetStage.adult
                  ? '${pet.xp} XP'
                  : '${pet.xp} / ${pet.nextStageXp} XP',
              style: TextStyle(color: palette.textMuted, fontSize: 10.5),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: pet.stageProgress,
            minHeight: 5,
            backgroundColor: palette.divider,
            valueColor: AlwaysStoppedAnimation(palette.halo),
          ),
        ),
        const SizedBox(height: 10),
        _StatBar(
          icon: Icons.restaurant_rounded,
          label: strings.get('petHunger'),
          value: pet.hunger,
          color: palette.coral,
        ),
        const SizedBox(height: 6),
        _StatBar(
          icon: Icons.favorite_rounded,
          label: strings.get('petJoy'),
          value: pet.joy,
          color: palette.accentSoft,
        ),
        const SizedBox(height: 6),
        _StatBar(
          icon: Icons.bolt_rounded,
          label: strings.get('petEnergy'),
          value: pet.energy,
          color: palette.halo,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            for (final action in PetAction.values) ...[
              Expanded(
                child: _ActionButton(
                  pet: pet,
                  action: action,
                  strings: strings,
                  now: now,
                  onTap: busy ? null : () => onAction(action),
                ),
              ),
              if (action != PetAction.values.last) const SizedBox(width: 6),
            ],
          ],
        ),
      ],
    );
  }
}

class _StatBar extends StatelessWidget {
  const _StatBar({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 5),
        SizedBox(
          width: 74,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: palette.textMuted, fontSize: 10.5),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: value / 100,
              minHeight: 4.5,
              backgroundColor: palette.divider,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 24,
          child: Text(
            '$value',
            textAlign: TextAlign.right,
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: 10,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.pet,
    required this.action,
    required this.strings,
    required this.now,
    required this.onTap,
  });

  final PetState pet;
  final PetAction action;
  final AppStrings strings;
  final DateTime now;
  final VoidCallback? onTap;

  IconData get _icon {
    if (action == PetAction.care) return Icons.volunteer_activism_rounded;
    if (action == PetAction.sleep) return Icons.bedtime_rounded;
    if (pet.species.isPlant) {
      return action == PetAction.feed
          ? Icons.water_drop_rounded
          : Icons.wb_sunny_rounded;
    }
    return action == PetAction.feed
        ? Icons.restaurant_rounded
        : Icons.sports_esports_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final left = pet.cooldownLeft(action, now);
    final cooling = left > Duration.zero;
    final label = strings.get(petActionKey(action, pet.species));
    final color = cooling ? palette.textMuted : palette.accent;
    final minutes = left.inMinutes;
    final seconds = left.inSeconds % 60;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: cooling ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: cooling ? 0.05 : 0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: cooling ? palette.divider : color.withValues(alpha: 0.35),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon, size: 17, color: color),
            const SizedBox(height: 3),
            Text(
              cooling
                  ? '$minutes:${seconds.toString().padLeft(2, '0')}'
                  : label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cooling ? palette.textMuted : palette.textPrimary,
                fontSize: 9.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AdoptForm extends StatelessWidget {
  const _AdoptForm({
    required this.strings,
    required this.animal,
    required this.species,
    required this.name,
    required this.busy,
    required this.onKind,
    required this.onSpecies,
    required this.onAdopt,
    required this.actionLabel,
  });

  final AppStrings strings;
  final bool animal;
  final PetSpecies species;
  final TextEditingController name;
  final bool busy;
  final ValueChanged<bool> onKind;
  final ValueChanged<PetSpecies> onSpecies;
  final VoidCallback onAdopt;
  final String actionLabel;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final options = PetSpecies.values
        .where((s) => s.isPlant != animal)
        .toList(growable: false);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          strings.get('petChooseKind'),
          style: TextStyle(
            color: palette.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final isAnimal in [false, true]) ...[
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => onKind(isAnimal),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    decoration: BoxDecoration(
                      color: animal == isAnimal
                          ? palette.accent.withValues(alpha: 0.16)
                          : palette.surface.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: animal == isAnimal
                            ? palette.accent.withValues(alpha: 0.6)
                            : palette.divider,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          isAnimal
                              ? Icons.pets_rounded
                              : Icons.local_florist_rounded,
                          size: 16,
                          color: animal == isAnimal
                              ? palette.accent
                              : palette.textMuted,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          strings.get(
                            isAnimal ? 'petKindAnimal' : 'petKindPlant',
                          ),
                          style: TextStyle(
                            color: animal == isAnimal
                                ? palette.textPrimary
                                : palette.textMuted,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (!isAnimal) const SizedBox(width: 8),
            ],
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            for (final option in options) ...[
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => onSpecies(option),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(2, 6, 2, 6),
                    decoration: BoxDecoration(
                      color: option == species
                          ? palette.accent.withValues(alpha: 0.14)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: option == species
                            ? palette.accent.withValues(alpha: 0.55)
                            : palette.divider,
                      ),
                    ),
                    child: Column(
                      children: [
                        PetPortrait(
                          pet: PetState.adopt(
                            chatId: 'preview',
                            species: option,
                            name: strings.get(option.nameKey),
                            adopterId: '',
                          ),
                          size: 52,
                          animate: false,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          strings.get(option.nameKey),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: option == species
                                ? palette.textPrimary
                                : palette.textMuted,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (option != options.last) const SizedBox(width: 6),
            ],
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: name,
                maxLength: 24,
                style: TextStyle(color: palette.textPrimary, fontSize: 13),
                decoration: InputDecoration(
                  hintText: strings.get('petNameHint'),
                  counterText: '',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 150,
              child: FilledButton(
                onPressed: busy ? null : onAdopt,
                style: FilledButton.styleFrom(
                  backgroundColor: palette.accent,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
                child: Text(
                  actionLabel,
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
            ),
          ],
        ),
        if (busy)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: LinearProgressIndicator(
              minHeight: 2,
              backgroundColor: palette.divider,
              valueColor: AlwaysStoppedAnimation(palette.accent),
            ),
          ),
      ],
    );
  }
}

/// Animated portrait of the shared pet. One painter for every species and
/// growth stage, with a gentle idle drift, rising bubbles and a mood-aware face.
class PetPortrait extends StatefulWidget {
  const PetPortrait({
    super.key,
    required this.pet,
    this.size = 120,
    this.animate = true,
    this.reaction = 0,
  });

  final PetState pet;
  final double size;
  final bool animate;
  final int reaction;

  @override
  State<PetPortrait> createState() => _PetPortraitState();
}

class _PetPortraitState extends State<PetPortrait>
    with TickerProviderStateMixin {
  late final AnimationController _idle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 5200),
  );
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _idle.repeat();
    if (widget.reaction > 0) _pop.forward(from: 0);
  }

  @override
  void didUpdateWidget(covariant PetPortrait oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate && !_idle.isAnimating) _idle.repeat();
    if (!widget.animate && _idle.isAnimating) _idle.stop();
    if (widget.reaction != oldWidget.reaction) _pop.forward(from: 0);
  }

  @override
  void dispose() {
    _idle.dispose();
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: Listenable.merge([_idle, _pop]),
        builder: (context, _) => CustomPaint(
          painter: _PetPainter(
            pet: widget.pet,
            t: widget.animate ? _idle.value : 0.35,
            pop: _pop.value,
          ),
        ),
      ),
    );
  }
}

class _PetPainter extends CustomPainter {
  _PetPainter({required this.pet, required this.t, required this.pop});

  final PetState pet;
  final double t;
  final double pop;

  static const _coral = Color(0xFFFF8A73);
  static const _coralDeep = Color(0xFFF2604F);
  static const _pearl = Color(0xFFFFF3E2);
  static const _emerald = Color(0xFF2FB894);
  static const _emeraldDeep = Color(0xFF14735C);
  static const _gold = Color(0xFFFFC96B);
  static const _eye = Color(0xFF3A1712);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 120, size.height / 120);
    final bob = math.sin(t * math.pi * 2) * 1.6;
    final breathe = 1 + math.sin(t * math.pi * 2) * 0.018 + pop * 0.05;
    canvas.translate(60, 62 + bob);
    canvas.scale(breathe, breathe);
    canvas.translate(-60, -62);

    _scene(canvas);
    switch (pet.species) {
      case PetSpecies.coral:
        _drawCoral(canvas);
      case PetSpecies.lotus:
        _lotus(canvas);
      case PetSpecies.seaweed:
        _seaweed(canvas);
      case PetSpecies.turtle:
        _turtle(canvas);
      case PetSpecies.fish:
        _fish(canvas);
      case PetSpecies.crab:
        _crab(canvas);
    }
    _bubbles(canvas);
    if (pet.isHappy) _sparkles(canvas);
    canvas.restore();
  }

  Paint _fill(Color color) => Paint()..color = color;

  Paint _gradient(List<Color> colors) => Paint()
    ..shader = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: colors,
    ).createShader(const Rect.fromLTWH(0, 0, 120, 120));

  Paint _stroke(Color color, double width) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  void _scene(Canvas canvas) {
    final glow = Paint()
      ..shader = RadialGradient(
        colors: [_emerald.withValues(alpha: 0.20), Colors.transparent],
      ).createShader(const Rect.fromLTWH(8, 8, 104, 104));
    canvas.drawCircle(const Offset(60, 62), 54, glow);
    canvas.drawOval(
      const Rect.fromLTWH(20, 92, 80, 14),
      _fill(_emeraldDeep.withValues(alpha: 0.22)),
    );
  }

  void _bubbles(Canvas canvas) {
    for (var i = 0; i < 3; i++) {
      final phase = (t + i / 3) % 1;
      final x = 26.0 + i * 24 + math.sin((t + i) * math.pi * 2) * 3;
      final y = 92 - phase * 62;
      canvas.drawCircle(
        Offset(x, y),
        1.4 + i * 0.7,
        _fill(_pearl.withValues(alpha: (1 - phase) * 0.5)),
      );
    }
  }

  void _sparkles(Canvas canvas) {
    for (final offset in const [
      Offset(26, 38),
      Offset(96, 52),
      Offset(86, 26),
    ]) {
      final alpha = 0.35 + 0.35 * math.sin(t * math.pi * 4 + offset.dx);
      final paint = _stroke(_gold.withValues(alpha: alpha), 1.4);
      canvas.drawLine(offset.translate(-3, 0), offset.translate(3, 0), paint);
      canvas.drawLine(offset.translate(0, -3), offset.translate(0, 3), paint);
    }
  }

  // --------------------------------------------------------------- faces

  void _face(
    Canvas canvas,
    Offset center, {
    double eyeGap = 7,
    double mouth = 4,
  }) {
    final happy = pet.isHappy;
    final sad = pet.isSad;
    final blink = (t % 1) > 0.96;
    for (final dx in [-eyeGap, eyeGap]) {
      final eye = center.translate(dx, 0);
      if (blink) {
        canvas.drawLine(
          eye.translate(-2.2, 0),
          eye.translate(2.2, 0),
          _stroke(_eye, 1.6),
        );
      } else {
        canvas.drawCircle(eye, 1.7, _fill(_eye));
        canvas.drawCircle(eye.translate(-0.5, -0.5), 0.55, _fill(_pearl));
      }
    }
    if (sad) {
      canvas.drawArc(
        Rect.fromCenter(
          center: center.translate(0, mouth + 2),
          width: mouth * 2,
          height: mouth,
        ),
        math.pi + 0.25,
        math.pi - 0.5,
        false,
        _stroke(_eye, 1.6),
      );
    } else {
      canvas.drawArc(
        Rect.fromCenter(
          center: center.translate(0, mouth + 1),
          width: mouth * 2.1,
          height: happy ? mouth * 1.8 : mouth * 1.2,
        ),
        0.2,
        math.pi - 0.4,
        false,
        _stroke(_eye, 1.6),
      );
    }
  }

  double get _stageScale => switch (pet.stage) {
    PetStage.seed => 0.68,
    PetStage.sprout => 0.82,
    PetStage.young => 0.93,
    PetStage.adult => 1.04,
  };

  void _egg(Canvas canvas) {
    canvas.drawOval(
      const Rect.fromLTWH(43, 52, 34, 42),
      _gradient([_pearl, _gold.withValues(alpha: 0.85)]),
    );
    canvas.drawOval(
      const Rect.fromLTWH(43, 52, 34, 42),
      _stroke(_coralDeep.withValues(alpha: 0.35), 1.6),
    );
    for (final dot in const [Offset(52, 66), Offset(66, 74), Offset(58, 84)]) {
      canvas.drawCircle(dot, 2.4, _fill(_coral.withValues(alpha: 0.55)));
    }
  }

  void _drawCoral(Canvas canvas) {
    canvas.save();
    canvas.translate(60, 88);
    canvas.scale(_stageScale);
    canvas.translate(-60, -88);
    canvas.drawOval(
      const Rect.fromLTWH(32, 86, 56, 16),
      _fill(const Color(0xFF0B3A2C)),
    );
    final body = Path()
      ..moveTo(50, 90)
      ..cubicTo(48, 70, 53, 56, 60, 48)
      ..cubicTo(67, 56, 72, 70, 70, 90)
      ..close();
    canvas.drawPath(body, _gradient([_coral, _coralDeep]));
    if (pet.stage != PetStage.seed) {
      canvas.drawPath(
        Path()
          ..moveTo(56, 62)
          ..cubicTo(44, 58, 38, 48, 36, 38),
        _stroke(_coral, 6),
      );
    }
    if (pet.stage == PetStage.young || pet.stage == PetStage.adult) {
      canvas.drawPath(
        Path()
          ..moveTo(64, 58)
          ..cubicTo(76, 54, 82, 44, 84, 34),
        _stroke(_coralDeep, 5.5),
      );
      canvas.drawCircle(const Offset(84, 31), 5, _fill(_gold));
    }
    if (pet.stage == PetStage.adult) {
      canvas.drawPath(
        Path()
          ..moveTo(60, 48)
          ..cubicTo(60, 40, 58, 34, 60, 28),
        _stroke(_gold, 3.5),
      );
      canvas.drawCircle(const Offset(60, 25), 4.5, _fill(_pearl));
      canvas.drawCircle(const Offset(60, 25), 4.5, _stroke(_gold, 1.5));
    }
    _face(canvas, const Offset(60, 70), eyeGap: 5.5, mouth: 3.5);
    canvas.restore();
  }

  void _lotus(Canvas canvas) {
    canvas.save();
    canvas.translate(60, 84);
    canvas.scale(_stageScale);
    canvas.translate(-60, -84);
    canvas.drawOval(
      const Rect.fromLTWH(24, 84, 72, 12),
      _fill(_emerald.withValues(alpha: 0.35)),
    );
    final petals = switch (pet.stage) {
      PetStage.seed => 0,
      PetStage.sprout => 4,
      PetStage.young => 6,
      PetStage.adult => 8,
    };
    if (petals == 0) {
      canvas.drawOval(
        const Rect.fromLTWH(49, 62, 22, 26),
        _gradient([_gold, _coral]),
      );
      canvas.drawOval(
        const Rect.fromLTWH(49, 62, 22, 26),
        _stroke(_coralDeep.withValues(alpha: 0.4), 1.4),
      );
    } else {
      for (var i = 0; i < petals; i++) {
        final angle = math.pi + i * math.pi / (petals - 1);
        final center = Offset(
          60 + math.cos(angle) * 17,
          77 + math.sin(angle) * 12,
        );
        canvas.save();
        canvas.translate(center.dx, center.dy);
        canvas.rotate(angle + math.pi / 2);
        canvas.drawOval(
          const Rect.fromLTWH(-7, -17, 14, 26),
          _gradient([_pearl, _coral.withValues(alpha: 0.9)]),
        );
        canvas.drawOval(
          const Rect.fromLTWH(-7, -17, 14, 26),
          _stroke(_coralDeep.withValues(alpha: 0.28), 1.1),
        );
        canvas.restore();
      }
      canvas.drawCircle(const Offset(60, 74), 10, _fill(_gold));
      _face(canvas, const Offset(60, 72), eyeGap: 4, mouth: 3);
    }
    canvas.restore();
  }

  void _seaweed(Canvas canvas) {
    canvas.save();
    canvas.translate(60, 90);
    canvas.scale(_stageScale);
    canvas.translate(-60, -90);
    canvas.drawOval(
      const Rect.fromLTWH(28, 88, 64, 14),
      _fill(_emeraldDeep.withValues(alpha: 0.5)),
    );
    final stems = pet.stage == PetStage.seed
        ? 1
        : (pet.stage == PetStage.sprout ? 2 : 3);
    for (var i = 0; i < stems; i++) {
      final x = 60 + (i - (stems - 1) / 2) * 16;
      final sway = math.sin(t * math.pi * 2 + i) * 5;
      final path = Path()
        ..moveTo(x - 7, 90)
        ..cubicTo(x - 12, 74, x + 8 + sway, 62, x + sway, 40 + i * 4);
      canvas.drawPath(path, _stroke(_emeraldDeep, 11));
      canvas.drawPath(path, _stroke(_emerald, 7));
      if (i == (stems - 1) ~/ 2) {
        final leafCenter = Offset(x + sway, 40 + i * 4);
        canvas.drawOval(
          Rect.fromCenter(center: leafCenter, width: 18, height: 12),
          _fill(_gold.withValues(alpha: 0.9)),
        );
        _face(canvas, leafCenter.translate(0, 0), eyeGap: 4.5, mouth: 2.5);
      }
    }
    canvas.restore();
  }

  void _turtle(Canvas canvas) {
    if (pet.stage == PetStage.seed) {
      _egg(canvas);
      return;
    }
    canvas.save();
    canvas.translate(60, 68);
    canvas.scale(_stageScale);
    canvas.translate(-60, -68);
    // Flippers.
    for (final point in const [Offset(38, 78), Offset(82, 78)]) {
      canvas.drawOval(
        Rect.fromCenter(center: point, width: 22, height: 11),
        _fill(_emeraldDeep.withValues(alpha: 0.85)),
      );
    }
    canvas.drawOval(
      const Rect.fromLTWH(32, 52, 56, 36),
      _gradient([_emerald, _emeraldDeep]),
    );
    final shell = Path()
      ..moveTo(40, 62)
      ..quadraticBezierTo(60, 46, 80, 62)
      ..quadraticBezierTo(60, 88, 40, 62)
      ..close();
    canvas.drawPath(shell, _fill(_coral.withValues(alpha: 0.9)));
    for (var i = -1; i <= 1; i++) {
      canvas.drawPath(
        Path()
          ..moveTo(60 + i * 12, 56)
          ..quadraticBezierTo(60 + i * 16, 68, 60 + i * 10, 78),
        _stroke(_coralDeep.withValues(alpha: 0.35), 1.4),
      );
    }
    final head = const Offset(88, 60);
    canvas.drawCircle(head, 11, _fill(_emerald));
    _face(canvas, head, eyeGap: 4, mouth: 3);
    if (pet.stage == PetStage.adult) {
      canvas.drawPath(
        Path()
          ..moveTo(46, 54)
          ..quadraticBezierTo(60, 42, 74, 54),
        _stroke(_gold, 2.4),
      );
    }
    canvas.restore();
  }

  void _fish(Canvas canvas) {
    if (pet.stage == PetStage.seed) {
      _egg(canvas);
      return;
    }
    canvas.save();
    canvas.translate(60, 64);
    canvas.scale(_stageScale);
    canvas.translate(-60, -64);
    final tail = Path()
      ..moveTo(38, 64)
      ..lineTo(20, 50)
      ..lineTo(24, 64)
      ..lineTo(20, 78)
      ..close();
    canvas.drawPath(tail, _fill(_coralDeep));
    canvas.drawOval(
      const Rect.fromLTWH(32, 46, 56, 38),
      _gradient([_coral, _gold]),
    );
    canvas.drawPath(
      Path()
        ..moveTo(58, 47)
        ..quadraticBezierTo(66, 36, 76, 47),
      _fill(_coralDeep.withValues(alpha: 0.8)),
    );
    canvas.drawPath(
      Path()
        ..moveTo(56, 62)
        ..quadraticBezierTo(66, 60, 72, 64),
      _stroke(_pearl.withValues(alpha: 0.55), 2.4),
    );
    _face(canvas, const Offset(74, 62), eyeGap: 4.5, mouth: 2.6);
    if (pet.stage == PetStage.adult) {
      for (final dot in const [
        Offset(46, 58),
        Offset(52, 70),
        Offset(40, 68),
      ]) {
        canvas.drawCircle(dot, 2.2, _fill(_pearl.withValues(alpha: 0.8)));
      }
    }
    canvas.restore();
  }

  void _crab(Canvas canvas) {
    if (pet.stage == PetStage.seed) {
      _egg(canvas);
      return;
    }
    canvas.save();
    canvas.translate(60, 70);
    canvas.scale(_stageScale);
    canvas.translate(-60, -70);
    final claw = _stroke(_coralDeep, 4.5);
    for (final side in [-1, 1]) {
      canvas.drawPath(
        Path()
          ..moveTo(60 + side * 24, 70)
          ..cubicTo(60 + side * 36, 62, 60 + side * 40, 48, 60 + side * 34, 42),
        claw,
      );
      final point = Offset(60 + side * 34, 39);
      canvas.drawCircle(point, 7, _fill(_coral));
      canvas.drawArc(
        Rect.fromCircle(center: point, radius: 7),
        side > 0 ? -2.4 : 0.6,
        1.6,
        false,
        _stroke(_coralDeep, 2.4),
      );
    }
    canvas.drawOval(
      const Rect.fromLTWH(36, 60, 48, 30),
      _gradient([_coral, _coralDeep]),
    );
    _face(canvas, const Offset(60, 68), eyeGap: 6, mouth: 3.4);
    for (final side in [-1, 1]) {
      for (var i = 0; i < 3; i++) {
        canvas.drawPath(
          Path()
            ..moveTo(60 + side * (16 + i * 4), 84)
            ..lineTo(60 + side * (22 + i * 6), 92),
          _stroke(_coralDeep.withValues(alpha: 0.8), 2.4),
        );
      }
    }
    if (pet.stage == PetStage.adult) {
      canvas.drawCircle(const Offset(60, 52), 4, _fill(_gold));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PetPainter oldDelegate) =>
      oldDelegate.pet != pet || oldDelegate.t != t || oldDelegate.pop != pop;
}
