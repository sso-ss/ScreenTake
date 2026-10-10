const navigation = document.getElementById('nav-links');
const menuToggle = document.querySelector('.menu-toggle');

function closeNavigation() {
  navigation.classList.remove('open');
  menuToggle.setAttribute('aria-expanded', 'false');
  menuToggle.setAttribute('aria-label', 'Open navigation');
}

menuToggle.addEventListener('click', () => {
  const isOpen = navigation.classList.toggle('open');
  menuToggle.setAttribute('aria-expanded', String(isOpen));
  menuToggle.setAttribute('aria-label', isOpen ? 'Close navigation' : 'Open navigation');
});
navigation.querySelectorAll('a').forEach(link => link.addEventListener('click', closeNavigation));
document.addEventListener('keydown', event => {
  if (event.key === 'Escape' && navigation.classList.contains('open')) {
    closeNavigation();
    menuToggle.focus();
  }
});

const downloadDialog = document.getElementById('download-dialog');
document.querySelectorAll('[data-download]').forEach(button => {
  button.addEventListener('click', () => downloadDialog.showModal());
});
downloadDialog.querySelector('.close-dialog').addEventListener('click', () => downloadDialog.close());
downloadDialog.addEventListener('click', event => {
  const bounds = downloadDialog.getBoundingClientRect();
  if (event.target === downloadDialog && (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom)) downloadDialog.close();
});

const promoDialog = document.getElementById('promo-dialog');
const promoVideo = promoDialog.querySelector('video');
const promoAudio = promoDialog.querySelector('audio');
const promoStatus = promoDialog.querySelector('.promo-status');

function showPromoPlaybackError(error) {
  if (error.name === 'AbortError' && !promoDialog.open) return;
  promoStatus.textContent = error.name === 'NotAllowedError'
    ? 'Press Play to start the video.'
    : 'The video could not play. Try reopening it or reloading the page.';
  promoStatus.hidden = false;
}

function syncPromoAudio() {
  if (Math.abs(promoAudio.currentTime - promoVideo.currentTime) > 0.15) {
    promoAudio.currentTime = promoVideo.currentTime;
  }
  promoAudio.muted = promoVideo.muted;
  promoAudio.volume = promoVideo.volume;
  promoAudio.playbackRate = promoVideo.playbackRate;
}

document.querySelector('[data-promo]').addEventListener('click', event => {
  if (event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return;
  event.preventDefault();
  promoStatus.hidden = true;
  promoDialog.showModal();
  promoVideo.muted = false;
  promoVideo.volume = 1;
  syncPromoAudio();
  Promise.all([promoVideo.play(), promoAudio.play()])
    .then(() => {
      promoStatus.hidden = true;
    })
    .catch(showPromoPlaybackError);
});
promoVideo.addEventListener('error', () => {
  promoStatus.textContent = 'The video could not load. Check your connection and reload the page.';
  promoStatus.hidden = false;
});
promoAudio.addEventListener('error', () => {
  promoStatus.textContent = 'The video sound could not load. Check your connection and reload the page.';
  promoStatus.hidden = false;
});
promoVideo.addEventListener('play', () => {
  syncPromoAudio();
  promoAudio.play()
    .then(() => {
      promoStatus.hidden = true;
    })
    .catch(showPromoPlaybackError);
});
promoVideo.addEventListener('pause', () => promoAudio.pause());
promoVideo.addEventListener('seeking', () => {
  promoAudio.currentTime = promoVideo.currentTime;
});
promoVideo.addEventListener('timeupdate', () => {
  if (Math.abs(promoAudio.currentTime - promoVideo.currentTime) > 0.2) {
    promoAudio.currentTime = promoVideo.currentTime;
  }
});
promoVideo.addEventListener('ratechange', syncPromoAudio);
promoVideo.addEventListener('volumechange', syncPromoAudio);
promoDialog.querySelector('.close-dialog').addEventListener('click', () => promoDialog.close());
promoDialog.addEventListener('keydown', event => {
  if (event.key === 'Escape') {
    event.preventDefault();
    promoDialog.close();
  }
});
promoDialog.addEventListener('click', event => {
  const bounds = promoDialog.getBoundingClientRect();
  if (event.target === promoDialog && (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom)) promoDialog.close();
});
promoDialog.addEventListener('close', () => {
  promoVideo.pause();
  promoVideo.currentTime = 0;
  promoAudio.pause();
  promoAudio.currentTime = 0;
});

const cursorPaths = {
  arrow: 'M13 7 52 34 34 37 26 55Z',
  hand: 'M24 33V13a5 5 0 0 1 10 0v15-4a4 4 0 0 1 8 0v5-2a4 4 0 0 1 8 0v4a4 4 0 0 1 8 0v12c0 11-8 17-19 17-7 0-11-4-15-8L12 37c-3-5 3-10 7-6l5 5Z',
  circle: 'M32 9a23 23 0 1 0 0 46 23 23 0 1 0 0-46Z'
};
function selectFeatureCursor(style) {
  document.querySelectorAll('[data-cursor]').forEach(option => {
    const selected = option.dataset.cursor === style;
    option.classList.toggle('selected', selected);
    option.setAttribute('aria-pressed', String(selected));
  });
  document.querySelector('#cursor-preview path').setAttribute('d', cursorPaths[style]);
}
function setFeatureCursorSize(size) {
  const roundedSize = Math.round(size / 10) * 10;
  document.getElementById('cursor-size').value = roundedSize;
  document.getElementById('cursor-size-value').value = `${roundedSize}%`;
  document.getElementById('cursor-preview').style.setProperty('--cursor-scale', size / 150);
}
document.querySelectorAll('[data-cursor]').forEach(button => {
  button.addEventListener('click', () => selectFeatureCursor(button.dataset.cursor));
});
document.getElementById('cursor-size').addEventListener('input', event => {
  setFeatureCursorSize(Number(event.target.value));
});

const workflowContent = {
  record: {
    title: 'Start with a good take.', image: 'assets/recording.png', alt: 'ScreenTake recording workspace with canvas and capture settings',
    width: 1416, height: 806,
    copy: 'Choose your screen, set up your microphone and camera, and record at 30 or 60 FPS. Pause and resume from the native capture toolbar.'
  },
  edit: {
    title: 'Keep the good parts.', image: 'assets/editor.png?v=3', alt: 'ScreenTake 0.1.10 editor with a sample video, original audio waveform, two voiceover takes, and separate audio levels',
    width: 1400, height: 850, version: 'ScreenTake · 0.1.10',
    copy: 'Trim, split, and reorder your clips. Record narration while watching your video, then move and trim each voiceover take on its own audio strip.'
  },
  export: {
    title: 'One last look. Then it’s yours.', image: 'assets/export.svg?v=3', alt: 'Illustration of a finished video with playback controls and a MOV file saved to your Mac',
    width: 1012, height: 640,
    copy: 'Preview your canvas, background, and edits, then save a MOV file to your Mac. Your recording is ready to share through the tools you already use.'
  }
};
const workflowTabs = [...document.querySelectorAll('[data-step]')];
function selectWorkflow(button) {
  workflowTabs.forEach(tab => {
    const selected = tab === button;
    tab.classList.toggle('active', selected);
    tab.setAttribute('aria-selected', String(selected));
    tab.tabIndex = selected ? 0 : -1;
  });
  const content = workflowContent[button.dataset.step];
  document.querySelector('.workflow-visual').dataset.step = button.dataset.step;
  document.getElementById('workflow-panel').setAttribute('aria-labelledby', button.id);
  document.getElementById('workflow-title').textContent = content.title;
  document.getElementById('workflow-copy').textContent = content.copy;
  const workflowVersion = document.getElementById('workflow-version');
  workflowVersion.textContent = content.version || '';
  workflowVersion.hidden = !content.version;
  const workflowImage = document.getElementById('workflow-image');
  workflowImage.src = content.image;
  workflowImage.alt = content.alt;
  workflowImage.width = content.width;
  workflowImage.height = content.height;
  document.dispatchEvent(new Event('workflowchange'));
}
workflowTabs.forEach((button, index) => {
  button.addEventListener('click', () => selectWorkflow(button));
  button.addEventListener('keydown', event => {
    let nextIndex = index;
    if (event.key === 'ArrowRight') nextIndex = (index + 1) % workflowTabs.length;
    else if (event.key === 'ArrowLeft') nextIndex = (index - 1 + workflowTabs.length) % workflowTabs.length;
    else if (event.key === 'Home') nextIndex = 0;
    else if (event.key === 'End') nextIndex = workflowTabs.length - 1;
    else return;
    event.preventDefault();
    selectWorkflow(workflowTabs[nextIndex]);
    workflowTabs[nextIndex].focus();
  });
});

selectWorkflow(workflowTabs[0]);

document.querySelectorAll('[data-background]').forEach(button => {
  button.addEventListener('click', () => {
    document.querySelectorAll('[data-background]').forEach(option => {
      option.classList.toggle('selected', option === button);
      option.setAttribute('aria-pressed', String(option === button));
    });
    const background = button.dataset.background;
    document.getElementById('canvas-stage').style.setProperty('--wallpaper', `url('assets/${background}.png')`);
    document.getElementById('background-name').textContent = background[0].toUpperCase() + background.slice(1);
  });
});
document.querySelectorAll('[data-ratio]').forEach(button => {
  button.addEventListener('click', () => {
    document.querySelectorAll('button[data-ratio]').forEach(option => {
      option.classList.toggle('selected', option === button);
      option.setAttribute('aria-pressed', String(option === button));
    });
    document.getElementById('canvas-frame').dataset.ratio = button.dataset.ratio;
  });
});

if (window.gsap) {
  const pageMotion = gsap.matchMedia();
  pageMotion.add('(prefers-reduced-motion: no-preference)', context => {
    const entrance = gsap.timeline({ defaults: { duration: .75, ease: 'power3.out' } });
    entrance.fromTo('.hero h1', { y: 30, opacity: 0 }, { y: 0, opacity: 1, clearProps: 'transform,opacity' })
      .fromTo('.hero-description', { y: 20, opacity: 0 }, { y: 0, opacity: 1, clearProps: 'transform,opacity' }, .15)
      .fromTo('.hero-actions > *, .compatibility', { y: 14, opacity: 0 }, { y: 0, opacity: 1, stagger: .08, clearProps: 'transform,opacity' }, .3);

    context.add('reveal', (target, delay) => {
      gsap.fromTo(target, { y: 26, opacity: 0 }, {
        y: 0, opacity: 1, duration: .7, delay, ease: 'power3.out', clearProps: 'transform,opacity'
      });
    });

    const revealObserver = new IntersectionObserver(entries => {
      const visible = entries.filter(entry => entry.isIntersecting);
      visible.forEach((entry, index) => {
        context.reveal(entry.target, Math.min(index * .09, .27));
        revealObserver.unobserve(entry.target);
      });
    }, { threshold: .12, rootMargin: '0px 0px -30px 0px' });
    document.querySelectorAll('.capabilities, .section-heading, .feature-card, .center-heading, .workflow-panel, .canvas-playground, .guide-steps > li, .guide-help, .guide-feedback, .faq-section, .closing-content').forEach(element => revealObserver.observe(element));

    const heroSection = document.querySelector('.hero');
    const heroFlow = createHeroFlow(document.querySelector('.hero-flow'));
    const heroWaveMotion = gsap.timeline({ paused: true });
    const heroFlowState = heroFlow?.state || { x: .5, y: .3, strength: 0 };
    if (heroFlow) heroWaveMotion.to(heroFlowState, { phase: Math.PI * 2, duration: 90, repeat: -1, ease: 'none', onUpdate: heroFlow.draw });
    const moveHeroWaveX = gsap.quickTo(heroFlowState, 'x', { duration: 1.4, ease: 'power3.out' });
    const moveHeroWaveY = gsap.quickTo(heroFlowState, 'y', { duration: 1.4, ease: 'power3.out' });
    const heroFlowStrength = gsap.quickTo(heroFlowState, 'strength', { duration: 1.8, ease: 'power2.out' });
    const followHeroPointer = event => {
      if (event.pointerType === 'touch' || featureMotionPaused || document.hidden) return;
      const bounds = heroSection.getBoundingClientRect();
      moveHeroWaveX((event.clientX - bounds.left) / bounds.width);
      moveHeroWaveY((event.clientY - bounds.top) / bounds.height);
      heroFlowStrength(1);
    };
    const centerHeroWaves = () => {
      if (featureMotionPaused || document.hidden) return;
      heroFlowStrength(0);
    };
    heroSection.addEventListener('pointermove', followHeroPointer, { passive: true });
    heroSection.addEventListener('pointerleave', centerHeroWaves);

    const waveMotion = gsap.timeline({ paused: true });
    document.querySelectorAll('.waveform i').forEach((bar, index) => {
      waveMotion.fromTo(bar, { scaleY: .22 + (index % 4) * .08 }, {
        scaleY: .85 + (index % 3) * .15, duration: .22 + (index % 5) * .075,
        repeat: -1, yoyo: true, ease: 'sine.inOut'
      }, (index % 7) * .045);
    });

    const zoomCanvas = document.querySelector('.zoom-demo');
    const demoPointer = zoomCanvas.querySelector('.demo-pointer');
    gsap.set(demoPointer, { left: 0, top: 0, right: 'auto', bottom: 'auto' });
    const pointerPosition = (horizontal, vertical) => ({
      x: () => 12 + Math.max(0, zoomCanvas.clientWidth - demoPointer.offsetWidth - 24) * horizontal,
      y: () => 12 + Math.max(0, zoomCanvas.clientHeight - demoPointer.offsetHeight - 24) * vertical
    });
    const pointerMotion = gsap.timeline({ paused: true, repeat: -1, repeatDelay: .35, defaults: { ease: 'power2.inOut' } });
    pointerMotion.fromTo(demoPointer, pointerPosition(.78, .72), { ...pointerPosition(.37, .32), duration: 1.6 })
      .to(demoPointer, { ...pointerPosition(.58, .44), duration: 1.25 }, '+=.25')
      .to(demoPointer, { ...pointerPosition(.3, .72), duration: 1.4 }, '+=.15')
      .addLabel('click')
      .to(demoPointer, { scale: .88, duration: .13 })
      .to(demoPointer, { scale: 1, duration: .2 })
      .to(demoPointer, { ...pointerPosition(.78, .72), duration: 1.6 }, '+=.35');
    const zoomWindow = zoomCanvas.querySelector('.demo-window');
    const zoomReadout = zoomCanvas.querySelector('.zoom-number');
    const updateZoomReadout = () => {
      zoomReadout.textContent = `${Number(gsap.getProperty(zoomWindow, 'scaleX')).toFixed(1)}×`;
    };
    gsap.set(zoomWindow, { transformOrigin: '35% 75%' });
    pointerMotion.fromTo(zoomWindow, { scale: 1 }, {
      scale: 2, duration: .8, ease: 'power2.inOut', immediateRender: false, onUpdate: updateZoomReadout
    }, 'click').to(zoomWindow, {
      scale: 1, duration: .8, ease: 'power2.inOut', onUpdate: updateZoomReadout
    }, 'click+=1.4');

    const cursorCard = document.querySelector('.cursor-card');
    const cursorState = { size: 150 };
    const cursorMotion = gsap.timeline({ paused: true, repeat: -1, defaults: { ease: 'sine.inOut' } });
    ['arrow', 'hand', 'circle'].forEach((style, index) => {
      cursorMotion.call(() => selectFeatureCursor(style))
        .to(cursorState, { size: [90, 120, 70][index], duration: 1.1, onUpdate: () => setFeatureCursorSize(cursorState.size) })
        .to(cursorState, { size: [240, 270, 210][index], duration: 1.7, onUpdate: () => setFeatureCursorSize(cursorState.size) }, '+=.4')
        .to(cursorState, { size: 150, duration: 1.1, onUpdate: () => setFeatureCursorSize(cursorState.size) }, '+=.5');
    });

    const highlightRing = document.querySelector('.highlight-ring');
    const highlightPointer = document.querySelector('.highlight-pointer');
    const highlightMotion = gsap.timeline({ paused: true, repeat: -1 });
    ['#ffd85c', '#ff806c', '#69cd98', '#6da9ff', '#ef8fc9', '#ffffff'].forEach(color => {
      highlightMotion.set(highlightRing, { borderColor: color, backgroundColor: `${color}55` })
        .to(highlightPointer, { scale: .9, duration: .13 })
        .fromTo(highlightRing, { scale: .2, opacity: .95 }, { scale: 1.35, opacity: 0, duration: 1.15, ease: 'power2.out' })
        .to(highlightPointer, { scale: 1, duration: .2 }, '<')
        .to({}, { duration: .55 });
    });

    const rippleMotion = gsap.timeline({ paused: true });
    const rings = document.querySelectorAll('.camera-orbit');
    gsap.set(rings, { width: 154, height: 154, borderColor: '#ad91d0', transformOrigin: '50% 50%' });
    rings.forEach((ring, index) => {
      rippleMotion.fromTo(ring, { scale: .52, opacity: .65 }, {
        scale: 1.8, opacity: 0, duration: 2.8, ease: 'sine.out', repeat: -1
      }, index * 1.4);
    });
    rippleMotion.fromTo('.camera-avatar', { borderRadius: '24%' }, {
      borderRadius: '50%', duration: 2, repeat: -1, yoyo: true, repeatDelay: .6, ease: 'sine.inOut'
    }, 0);

    const recordVisual = document.querySelector('.workflow-visual');
    const recordTime = document.querySelector('.record-demo-time');
    const recordClock = { seconds: 4 };
    const recordMotion = gsap.timeline({ paused: true, repeat: -1, repeatDelay: .6 });
    recordMotion.fromTo('.record-demo-pointer', { left: '24%', top: '45%' }, { left: '68%', top: '64%', duration: 2.4, ease: 'power2.inOut' })
      .fromTo('.record-demo-pointer i', { scale: .3, opacity: 0 }, { scale: 1.6, opacity: .7, duration: .5 }, 2.4)
      .to('.record-demo-pointer i', { opacity: 0, duration: .5 }, 2.9)
      .to('.record-demo-pointer', { left: '40%', top: '36%', duration: 2.6, ease: 'power2.inOut' }, 3.2)
      .to('.record-demo-pointer', { left: '24%', top: '45%', duration: 1.8, ease: 'power2.inOut' }, 6)
      .fromTo(recordClock, { seconds: 4 }, { seconds: 12, duration: 8, ease: 'none', onUpdate: () => {
        recordTime.textContent = `00:${String(Math.floor(recordClock.seconds)).padStart(2, '0')}`;
      } }, 0);
    recordMotion.fromTo('.record-demo-dot', { opacity: 1 }, { opacity: .4, repeat: 9, yoyo: true, duration: .4 }, 0);
    document.querySelectorAll('.record-demo-meter i').forEach((bar, index) => {
      recordMotion.fromTo(bar, { scaleY: .3 }, { scaleY: 1, duration: .4, repeat: 17, yoyo: true, ease: 'sine.inOut' }, index * .1);
    });

    const voiceoverPreview = document.querySelector('.voiceover-preview');
    const voiceoverTime = voiceoverPreview.querySelector('.voiceover-time');
    const voiceoverTakes = voiceoverPreview.querySelectorAll('.voiceover-take');
    const voiceoverClock = { seconds: 0 };
    // Clip positions match the 8/43/9/34/6 timeline grid, over ten seconds.
    const voiceoverMotion = gsap.timeline({ paused: true, repeat: -1, repeatDelay: 1.2 });
    voiceoverMotion.fromTo('.voiceover-playhead', { left: '0%' }, { left: '100%', duration: 10, ease: 'none' }, 0)
      .fromTo(voiceoverClock, { seconds: 0 }, { seconds: 10, duration: 10, ease: 'none', onUpdate: () => {
        voiceoverTime.textContent = `00:${String(Math.floor(voiceoverClock.seconds)).padStart(2, '0')} / 00:10`;
      } }, 0)
      .fromTo(voiceoverTakes[0], { clipPath: 'inset(0 100% 0 0)' }, { clipPath: 'inset(0 0% 0 0)', duration: 4.3, ease: 'none' }, .8)
      .fromTo(voiceoverTakes[1], { clipPath: 'inset(0 100% 0 0)' }, { clipPath: 'inset(0 0% 0 0)', duration: 3.4, ease: 'none' }, 6);

    const featureLoops = new Map([
      [voiceoverPreview, voiceoverMotion],
      [recordVisual, recordMotion],
      [heroSection, heroWaveMotion],
      [document.querySelector('.audio-card'), waveMotion],
      [document.querySelector('.zoom-card'), pointerMotion],
      [cursorCard, cursorMotion],
      [document.querySelector('.highlight-card'), highlightMotion],
      [document.querySelector('.camera-card'), rippleMotion]
    ]);
    const visibleLoops = new Set();
    const motionToggle = document.getElementById('feature-motion-toggle');
    let featureMotionPaused = false;
    const syncFeatureMotion = () => {
      featureLoops.forEach((animation, card) => {
        const tryingCursor = card === cursorCard && (cursorCard.matches(':hover') || cursorCard.contains(document.activeElement));
        const inactiveRecord = card === recordVisual && recordVisual.dataset.step !== 'record';
        animation.paused(featureMotionPaused || document.hidden || !visibleLoops.has(card) || tryingCursor || inactiveRecord);
      });
    };
    const loopObserver = new IntersectionObserver(entries => {
      entries.forEach(entry => {
        if (entry.isIntersecting) visibleLoops.add(entry.target);
        else visibleLoops.delete(entry.target);
      });
      syncFeatureMotion();
    }, { threshold: .1 });
    featureLoops.forEach((animation, card) => loopObserver.observe(card));
    const pointerResize = new ResizeObserver(() => {
      pointerMotion.invalidate().restart();
      syncFeatureMotion();
    });
    pointerResize.observe(zoomCanvas);
    const toggleFeatureMotion = () => {
      featureMotionPaused = !featureMotionPaused;
      if (featureMotionPaused) {
        moveHeroWaveX.tween.pause();
        moveHeroWaveY.tween.pause();
        heroFlowStrength.tween.pause();
      }
      motionToggle.setAttribute('aria-checked', String(!featureMotionPaused));
      const motionLabel = featureMotionPaused ? 'Turn on motion' : 'Turn off motion';
      motionToggle.querySelector('.motion-label').textContent = motionLabel;
      motionToggle.title = motionLabel;
      syncFeatureMotion();
    };
    motionToggle.hidden = false;
    motionToggle.setAttribute('aria-checked', 'true');
    motionToggle.querySelector('.motion-label').textContent = 'Turn off motion';
    motionToggle.title = 'Turn off motion';
    motionToggle.addEventListener('click', toggleFeatureMotion);
    document.addEventListener('visibilitychange', syncFeatureMotion);
    document.addEventListener('workflowchange', syncFeatureMotion);
    const syncCursorFocus = () => queueMicrotask(syncFeatureMotion);
    cursorCard.addEventListener('pointerenter', syncFeatureMotion);
    cursorCard.addEventListener('pointerleave', syncFeatureMotion);
    cursorCard.addEventListener('focusin', syncFeatureMotion);
    cursorCard.addEventListener('focusout', syncCursorFocus);

    context.add('interaction', event => {
      if (event.target.closest('[data-step]')) {
        gsap.fromTo(['#workflow-image', '.workflow-description'], { opacity: .25, y: 12 }, {
          opacity: 1, y: 0, duration: .4, stagger: .05, ease: 'power2.out', overwrite: true, clearProps: 'transform,opacity'
        });
      }
      if (event.target.closest('[data-background], button[data-ratio]')) {
        gsap.fromTo('.sample-window', { scale: .975, opacity: .7 }, {
          scale: 1, opacity: 1, duration: .45, ease: 'power2.out', overwrite: true, clearProps: 'transform,opacity'
        });
      }
      if (event.target.closest('[data-download]')) {
        gsap.fromTo(downloadDialog, { y: 16, scale: .97, opacity: 0 }, {
          y: 0, scale: 1, opacity: 1, duration: .3, ease: 'power3.out', overwrite: true, clearProps: 'transform,opacity'
        });
      }
    });
    document.addEventListener('click', context.interaction);

    return () => {
      revealObserver.disconnect();
      loopObserver.disconnect();
      pointerResize.disconnect();
      zoomReadout.textContent = '1×';
      heroSection.removeEventListener('pointermove', followHeroPointer);
      heroSection.removeEventListener('pointerleave', centerHeroWaves);
      heroFlow?.dispose();
      cursorCard.removeEventListener('pointerenter', syncFeatureMotion);
      cursorCard.removeEventListener('pointerleave', syncFeatureMotion);
      cursorCard.removeEventListener('focusin', syncFeatureMotion);
      cursorCard.removeEventListener('focusout', syncCursorFocus);
      selectFeatureCursor('arrow');
      setFeatureCursorSize(150);
      motionToggle.hidden = true;
      motionToggle.removeEventListener('click', toggleFeatureMotion);
      document.removeEventListener('visibilitychange', syncFeatureMotion);
      document.removeEventListener('workflowchange', syncFeatureMotion);
      recordTime.textContent = '00:04';
      voiceoverTime.textContent = '00:05 / 00:10';
      document.removeEventListener('click', context.interaction);
    };
  });
}
