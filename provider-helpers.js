(function (global) {
  'use strict';

  var DOCTOR_PREFIX_RE = /^(?:د\.|د\s|دكتورة?|dr)/i;

  function formatProviderName(doc) {
    if (!doc) return '';
    var displayName = doc.display_name != null ? String(doc.display_name).trim() : '';
    var rawName = (doc.name != null ? doc.name : doc.doctor_name) != null
      ? String(doc.name != null ? doc.name : doc.doctor_name).trim()
      : '';
    var providerType = doc.provider_type != null && String(doc.provider_type).trim()
      ? String(doc.provider_type).trim().toLowerCase()
      : 'doctor';

    var base = displayName;
    if (!base) {
      base = rawName;
      var sepIdx = base.search(/ - | \| /);
      if (sepIdx !== -1) {
        base = base.slice(0, sepIdx).trim();
      }
      var chars = Array.from(base);
      if (chars.length > 40) {
        base = chars.slice(0, 40).join('').trimEnd() + '…';
      }
    }

    if (!base) return '';

    if (providerType === 'doctor' && !DOCTOR_PREFIX_RE.test(base)) {
      return 'د. ' + base;
    }

    return base;
  }

  function getSpecialtyIcon(specialtyName) {
    var s = String(specialtyName || '').trim();
    if (!s) return '🩺';

    if (s.indexOf('أسنان') !== -1 || s.indexOf('اسنان') !== -1) return '🦷';
    if (s.indexOf('أطفال') !== -1 || s.indexOf('اطفال') !== -1) return '👶';
    if (s.indexOf('عظام') !== -1) return '🦴';
    if (s.indexOf('أنف') !== -1 || s.indexOf('انف') !== -1 || s.indexOf('أذن') !== -1 || s.indexOf('اذن') !== -1 || s.indexOf('حنجرة') !== -1) return '👂';
    if (s.indexOf('باطن') !== -1) return '🩺';
    if (s.indexOf('جلد') !== -1) return '🧴';
    if (s.indexOf('عيون') !== -1 || s.indexOf('رمد') !== -1) return '👁️';
    if (s.indexOf('قلب') !== -1 || s.indexOf('أوعية') !== -1 || s.indexOf('اوعية') !== -1) return '❤️';
    if (s.indexOf('نسا') !== -1 || s.indexOf('توليد') !== -1) return '🤰';
    if (s.indexOf('نفس') !== -1) return '🧠';

    return '🩺';
  }

  global.E7gezlyHelpers = {
    formatProviderName: formatProviderName,
    getSpecialtyIcon: getSpecialtyIcon
  };
})(window);
