    bool handwritingContext(const int voice,
                            msr::render::HandwritingContext& output,
                            std::string& errorMessage)
    {
        errorMessage.clear();
        output = {};
        HandwritingAnchor anchor;
        if (!resolveHandwritingSelection(voice, anchor, errorMessage)) {
            return false;
        }
        if (m_handwritingAnchor && sameHandwritingAnchor(*m_handwritingAnchor, anchor)) {
            output = m_handwritingAnchor->context;
            return true;
        }
        static std::atomic<uint64_t> nextToken { 0 };
        anchor.context.token = std::to_string(++nextToken);
        output = anchor.context;
        m_handwritingAnchor = std::move(anchor);
        return true;
    }

    bool previewHandwriting(const std::string& contextToken,
                            const std::vector<msr::render::HandwritingEvent>& events,
                            msr::render::RenderedPage& output,
                            std::string& errorMessage)
    {
        errorMessage.clear();
        output = {};
        HandwritingAnchor anchor;
        if (!validateHandwritingContext(contextToken, events, anchor, errorMessage)) {
            return false;
        }

        // MasterScore::clone serializes and reloads the engine representation in
        // memory. Every speculative command belongs to that independent score.
        std::unique_ptr<mu::engraving::MasterScore> clone(m_masterScore->clone());
        if (!clone) {
            errorMessage = "MuseScore could not create the handwriting preview.";
            return false;
        }
        mu::engraving::Score* previewScore = clone.get();
        if (m_activePartIndex) {
            const auto& parts = clone->parts();
            const int partIndex = *m_activePartIndex;
            if (partIndex < 0 || partIndex >= static_cast<int>(parts.size())) {
                errorMessage = "The selected part is unavailable in the handwriting preview.";
                return false;
            }
            mu::engraving::Excerpt* excerpt = nullptr;
            for (mu::engraving::Excerpt* candidate : clone->excerpts()) {
                if (candidate && candidate->initialPartId() == parts.at(partIndex)->id()) {
                    excerpt = candidate;
                    break;
                }
            }
            if (excerpt) {
                clone->initExcerpt(excerpt);
            } else {
                auto excerpts = mu::engraving::Excerpt::createExcerptsFromParts({ parts.at(partIndex) }, clone.get());
                if (excerpts.empty()) {
                    errorMessage = "MuseScore could not create the handwriting preview part.";
                    return false;
                }
                excerpt = excerpts.front();
                clone->initAndAddExcerpt(excerpt, true);
            }
            previewScore = excerpt->excerptScore();
        }
        if (!previewScore) {
            errorMessage = "MuseScore could not open the handwriting preview part.";
            return false;
        }
        previewScore->setStyle(anchor.score->style());
        previewScore->setLayoutMode(mu::engraving::LayoutMode::PAGE);
        previewScore->setLayoutAll();
        previewScore->doLayout();
        mu::engraving::Measure* measure = previewScore->tick2measure(anchor.measure->tick());
        if (!measure || !writeHandwritingEvents(previewScore, measure, anchor.context.staffIndex,
                                                anchor.context.voice, events, errorMessage)) {
            return false;
        }
        previewScore->deselectAll();
        previewScore->setLayoutAll();
        previewScore->doLayout();
        const mu::engraving::System* system = measure->system();
        if (!system || !system->page()) {
            errorMessage = "The handwriting preview did not produce a page.";
            return false;
        }
        return renderHandwritingPage(previewScore, measure, anchor.context.staffIndex, output, errorMessage);
    }

    bool applyHandwriting(const std::string& contextToken,
                          const std::vector<msr::render::HandwritingEvent>& events,
                          msr::render::ScoreEditState& output,
                          std::string& errorMessage)
    {
        errorMessage.clear();
        HandwritingAnchor anchor;
        if (!validateHandwritingContext(contextToken, events, anchor, errorMessage)) {
            return false;
        }
        if (!writeHandwritingEvents(anchor.score, anchor.measure, anchor.context.staffIndex,
                                    anchor.context.voice, events, errorMessage)) {
            return false;
        }
        markLinkedScoresForLayout(anchor.score);
        refreshAfterEdit();
        m_handwritingAnchor.reset();
        output = makeEditState(anchor.score);
        return true;
    }

    struct HandwritingAnchor {
        msr::render::HandwritingContext context;
        mu::engraving::Score* score = nullptr;
        mu::engraving::Measure* measure = nullptr;
        int revision = 0;
        int inputVoice = 0;
        size_t undoIndex = 0;
    };

    bool sameHandwritingAnchor(const HandwritingAnchor& first, const HandwritingAnchor& second) const
    {
        const auto& a = first.context;
        const auto& b = second.context;
        return first.score == second.score && first.measure == second.measure && first.revision == second.revision
            && first.undoIndex == second.undoIndex && first.inputVoice == second.inputVoice && a.voice == b.voice && a.staffIndex == b.staffIndex
            && a.pageIndex == b.pageIndex && a.durationTicks == b.durationTicks && a.key == b.key && a.clef == b.clef
            && a.measureRect.normalizedX == b.measureRect.normalizedX && a.measureRect.normalizedY == b.measureRect.normalizedY
            && a.measureRect.normalizedWidth == b.measureRect.normalizedWidth
            && a.measureRect.normalizedHeight == b.measureRect.normalizedHeight
            && a.staffTopNormalizedY == b.staffTopNormalizedY && a.staffHalfStepNormalizedY == b.staffHalfStepNormalizedY
            && a.inputStartNormalizedX == b.inputStartNormalizedX && a.inputEndNormalizedX == b.inputEndNormalizedX;
    }

    bool emptyHandwritingStaff(mu::engraving::Score* score,
                               mu::engraving::Measure* measure,
                               const mu::engraving::staff_idx_t staffIndex,
                               std::string& errorMessage) const
    {
        mu::engraving::Staff* staff = score->staff(staffIndex);
        const auto startTick = measure->tick();
        const auto clef = staff->clef(startTick);
        if (!isStandardStaff(staff, startTick) || staff->lines(startTick) != 5
            || staff->staffType(startTick)->stepOffset() != 0
            || (clef != mu::engraving::ClefType::G && clef != mu::engraving::ClefType::F)
            || staff->timeStretch(startTick) != mu::engraving::Fraction(1, 1)
            || measure->isMeasureRepeatGroup(staffIndex)) {
            errorMessage = "Write mode needs an empty five-line treble or bass staff without a local meter or measure repeat.";
            return false;
        }
        const auto firstTrack = staffIndex * mu::engraving::VOICES;
        const auto endTrack = firstTrack + mu::engraving::VOICES;
        const auto* instrument = staff->part()->instrument(startTick);
        for (mu::engraving::Segment* segment = measure->first(); segment; segment = segment->next()) {
            if (segment->tick() >= measure->endTick()) {
                break;
            }
            if (!isStandardStaff(staff, segment->tick()) || staff->clef(segment->tick()) != clef
                || staff->key(segment->tick()) != staff->key(startTick)
                || staff->part()->instrument(segment->tick()) != instrument
                || staff->staffType(segment->tick()) != staff->staffType(startTick)) {
                errorMessage = "Choose a bar with one clef, key, and instrument throughout.";
                return false;
            }
            if (!segment->isChordRestType()) {
                continue;
            }
            for (auto track = firstTrack; track < endTrack; ++track) {
                if (mu::engraving::EngravingItem* item = segment->element(track)) {
                    if (!item->isRest() || mu::engraving::toRest(item)->tuplet()) {
                        errorMessage = "Write mode needs a bar containing only ordinary rests in every voice of this staff.";
                        return false;
                    }
                }
            }
            for (const mu::engraving::EngravingItem* item : segment->annotations()) {
                if (!item->systemFlag() && item->track() >= firstTrack && item->track() < endTrack) {
                    errorMessage = "Choose an empty bar without staff markings before writing.";
                    return false;
                }
            }
        }
        return true;
    }

    bool resolveHandwritingSelection(const int voice,
                                      HandwritingAnchor& anchor,
                                      std::string& errorMessage) const
    {
        if (!supportsEditing() || m_viewTransposeActiveScore || voice < 0 || voice >= static_cast<int>(mu::engraving::VOICES)) {
            errorMessage = "Write mode is unavailable for this score or voice.";
            return false;
        }
        mu::engraving::Score* score = activeScore();
        if (score->readOnly() || !score->undoStack() || score->undoStack()->isLocked() || score->undoStack()->hasActiveCommand()) {
            errorMessage = "Finish the current edit before entering Write mode.";
            return false;
        }
        mu::engraving::Measure* startMeasure = nullptr;
        mu::engraving::Measure* endMeasure = nullptr;
        mu::engraving::staff_idx_t staffIndex = muse::nidx;
        if (selectedMeasureRange(score, &startMeasure, &endMeasure)) {
            if (startMeasure != endMeasure || score->selection().staffEnd() != score->selection().staffStart() + 1) {
                errorMessage = "Select exactly one empty bar on one staff for Write mode.";
                return false;
            }
            staffIndex = score->selection().staffStart();
        } else if (mu::engraving::ChordRest* selected = selectedChordRest(score)) {
            startMeasure = endMeasure = selected->measure();
            staffIndex = selected->staffIdx();
        }
        if (!startMeasure || staffIndex >= score->nstaves() || startMeasure->isMMRest()) {
            errorMessage = "Select one empty bar or its rest before entering Write mode.";
            return false;
        }
        mu::engraving::Staff* staff = score->staff(staffIndex);
        const auto tick = startMeasure->tick();
        const auto track = staffIndex * mu::engraving::VOICES + voice;
        if (!percussionTrackIsEditable(score, track, false) || !emptyHandwritingStaff(score, startMeasure, staffIndex, errorMessage)) {
            if (errorMessage.empty()) {
                errorMessage = "This voice is unavailable in the selected part.";
            }
            return false;
        }
        // An excerpt can hide music. Require the source staff to be empty too.
        if (!score->isMaster()) {
            mu::engraving::Staff* masterStaff = m_masterScore->staffById(staff->id());
            mu::engraving::Measure* masterMeasure = m_masterScore->tick2measure(tick);
            if (!masterStaff || !masterMeasure || !emptyHandwritingStaff(m_masterScore.get(), masterMeasure, masterStaff->idx(), errorMessage)) {
                return false;
            }
        }
        mu::engraving::System* system = startMeasure->system();
        mu::engraving::Page* page = system ? system->page() : nullptr;
        mu::engraving::SysStaff* systemStaff = system ? system->staff(staffIndex) : nullptr;
        const double halfStep = staff->spatium(tick) * staff->staffType(tick)->lineDistance().val() * 0.5;
        if (!page || !systemStaff || !systemStaff->show() || !staff->show() || page->width() <= 0.0 || page->height() <= 0.0 || halfStep <= 0.0) {
            errorMessage = "The selected staff has no writable page geometry.";
            return false;
        }
        const auto ticks = startMeasure->ticks().ticks();
        if (ticks <= 0) {
            errorMessage = "The selected bar has an unsupported duration.";
            return false;
        }
        auto& context = anchor.context;
        anchor.score = score;
        anchor.measure = startMeasure;
        anchor.revision = m_playbackStreamRevision;
        anchor.inputVoice = static_cast<int>(score->inputState().voice());
        anchor.undoIndex = score->undoStack()->currentIndex();
        context.pageIndex = static_cast<int>(score->pageIdx(page));
        context.measureIndex = zeroBasedMeasureIndex(score, startMeasure);
        context.staffIndex = static_cast<int>(staffIndex);
        context.voice = voice;
        context.measureStartTick = tick.ticks();
        context.durationTicks = ticks;
        const auto meter = currentTimeSignatureForSelection(score, startMeasure);
        context.timeSignatureNumerator = meter.numerator();
        context.timeSignatureDenominator = meter.denominator();
        context.clef = staff->clef(tick) == mu::engraving::ClefType::G ? "treble" : "bass";
        context.key = static_cast<int>(staff->key(tick));
        const double staffTop = system->staffYpage(staffIndex) + staff->staffType(tick)->yoffset().val() * staff->spatium(tick);
        context.staffTopNormalizedY = staffTop / page->height();
        context.staffHalfStepNormalizedY = halfStep / page->height();
        const auto bar = startMeasure->staffPageBoundingRect(staffIndex);
        const double top = std::max(0.0, staffTop - halfStep * 8.0);
        const double bottom = std::min(page->height(), staffTop + halfStep * 16.0);
        context.measureRect = { bar.left() / page->width(), top / page->height(), bar.width() / page->width(), (bottom - top) / page->height() };
        mu::engraving::Segment* firstSegment = startMeasure->first(mu::engraving::SegmentType::ChordRest);
        context.inputStartNormalizedX = firstSegment ? firstSegment->pagePos().x() / page->width() : context.measureRect.normalizedX;
        context.inputEndNormalizedX = (bar.right() - halfStep * 2.0) / page->width();
        if (context.inputEndNormalizedX <= context.inputStartNormalizedX) {
            errorMessage = "The selected bar is too narrow for Write mode.";
            return false;
        }
        return true;
    }

    bool validateHandwritingContext(const std::string& token,
                                    const std::vector<msr::render::HandwritingEvent>& events,
                                    HandwritingAnchor& anchor,
                                    std::string& errorMessage) const
    {
        if (!m_handwritingAnchor || token.empty() || token != m_handwritingAnchor->context.token
            || !resolveHandwritingSelection(m_handwritingAnchor->context.voice, anchor, errorMessage)
            || !sameHandwritingAnchor(*m_handwritingAnchor, anchor)) {
            errorMessage = "The writing target changed. Select the empty bar again before applying this ink.";
            return false;
        }
        if (events.empty() || events.size() > 128) {
            errorMessage = "Write between one and 128 notes or rests before previewing.";
            return false;
        }
        int64_t offset = 0;
        for (const auto& event : events) {
            const auto type = durationTypeForCode(event.durationCode);
            if (type == mu::engraving::DurationType::V_INVALID || event.dots < 0 || event.dots > 2
                || event.accidentalKind < -1 || event.accidentalKind > 2 || event.staffLine < -100 || event.staffLine > 100
                || (event.offsetTicks != -1 && event.offsetTicks != offset)) {
                errorMessage = "The handwriting proposal contains an unsupported symbol, duration, or beat position.";
                return false;
            }
            mu::engraving::TDuration duration(type);
            duration.setDots(event.dots);
            offset += duration.fraction().ticks();
            if (offset > anchor.context.durationTicks) {
                errorMessage = "The written rhythm does not fit inside the selected bar.";
                return false;
            }
        }
        return true;
    }

    bool writeHandwritingEvents(mu::engraving::Score* score,
                                 mu::engraving::Measure* measure,
                                 const int staffIndex,
                                 const int voice,
                                 const std::vector<msr::render::HandwritingEvent>& events,
                                 std::string& errorMessage)
    {
        errorMessage.clear();
        const auto previousInput = score->inputState();
        const auto previousSelection = score->selection();
        const auto firstUndoIndex = score->undoStack()->currentIndex();
        auto& input = score->inputState();
        const auto track = staffIndex * mu::engraving::VOICES + voice;
        auto tick = measure->tick();
        score->startCmd(muse::TranslatableString::untranslatable("Magistris apply handwriting"));
        input.setNoteEntryMode(false);
        input.setNoteEntryMethod(mu::engraving::NoteEntryMethod::BY_DURATION);
        mu::engraving::ChordRest* lastInserted = nullptr;
        for (const auto& event : events) {
            mu::engraving::Segment* segment = measure->findSegment(mu::engraving::SegmentType::ChordRest, tick);
            if (!segment) {
                errorMessage = "MuseScore could not locate a beat in the handwriting proposal.";
                break;
            }
            input.setTrack(track);
            input.setSegment(segment);
            input.setRest(event.rest);
            input.setAccidentalType(mu::engraving::AccidentalType::NONE);
            mu::engraving::TDuration duration(durationTypeForCode(event.durationCode));
            duration.setDots(event.dots);
            input.setDuration(duration);
            score->expandVoice(segment, track);
            mu::engraving::NoteVal note;
            if (!event.rest) {
                mu::engraving::Position position;
                position.segment = segment;
                position.staffIdx = staffIndex;
                position.line = event.staffLine;
                bool invalid = false;
                note = score->noteValForPosition(position,
                    event.accidentalKind < 0 ? mu::engraving::AccidentalType::NONE : *accidentalTypeForKind(event.accidentalKind), invalid);
                if (invalid || !mu::engraving::pitchIsValid(note.pitch)) {
                    errorMessage = "A written note is outside the supported pitch range.";
                    break;
                }
            }
            mu::engraving::Segment* inserted = score->setNoteRest(segment, track, note, duration.fraction(),
                mu::engraving::DirectionV::AUTO, !event.rest && event.accidentalKind >= 0, {});
            lastInserted = inserted ? mu::engraving::InputState::chordRest(inserted->element(track)) : nullptr;
            if (!lastInserted || lastInserted->tick() != tick || lastInserted->actualTicks() != duration.fraction()
                || lastInserted->isRest() != event.rest || (lastInserted->isChord()
                    && (mu::engraving::toChord(lastInserted)->notes().size() != 1 || mu::engraving::toChord(lastInserted)->upNote()->pitch() != note.pitch))) {
                errorMessage = "MuseScore could not insert every written event at its intended beat.";
                break;
            }
            tick += duration.fraction();
        }
        if (!errorMessage.empty() || mu::engraving::MScore::_error != mu::engraving::MsError::MS_NO_ERROR) {
            score->deselectAll();
            score->endCmd(true);
            score->setInputState(previousInput);
            score->setSelection(previousSelection);
            if (errorMessage.empty()) {
                errorMessage = "MuseScore rejected the handwriting proposal.";
            }
            return false;
        }
        if (lastInserted) {
            score->select(noteOrRestSelectionItem(lastInserted), mu::engraving::SelectType::SINGLE, staffIndex);
        }
        input.setNoteEntryMode(previousInput.noteEntryMode());
        input.setRest(previousInput.rest());
        input.setAccidentalType(mu::engraving::AccidentalType::NONE);
        measure->checkMultiVoices(staffIndex);
        score->endCmd();
        const auto finalUndoIndex = score->undoStack()->currentIndex();
        if (finalUndoIndex > firstUndoIndex) {
            if (finalUndoIndex > firstUndoIndex + 1) {
                score->undoStack()->mergeCommands(firstUndoIndex);
            }
            return true;
        }
        // endCmd discards an empty macro or rolls it back on an engine error.
        // No committed score change exists in this branch, so restore the UI state.
        score->setInputState(previousInput);
        score->setSelection(previousSelection);
        errorMessage = "MuseScore could not finish the handwriting edit.";
        return false;
    }

    bool renderHandwritingPage(mu::engraving::Score* score,
                               mu::engraving::Measure* measure,
                               const int staffIndex,
                               msr::render::RenderedPage& output,
                               std::string& errorMessage) const
    {
        if (!m_scoreRenderer()) {
            errorMessage = "The handwriting preview renderer is unavailable.";
            return false;
        }
        mu::engraving::Page* page = measure->system()->page();
        const int pageIndex = static_cast<int>(score->pageIdx(page));
        mu::engraving::RectF crop = measure->staffPageBoundingRect(staffIndex);
        std::vector<const mu::engraving::EngravingItem*> items;
        for (mu::engraving::Segment* segment = measure->first(mu::engraving::SegmentType::ChordRest);
             segment; segment = segment->next(mu::engraving::SegmentType::ChordRest)) {
            for (auto track = staffIndex * mu::engraving::VOICES; track < (staffIndex + 1) * mu::engraving::VOICES; ++track) {
                mu::engraving::ChordRest* chordRest = mu::engraving::InputState::chordRest(segment->element(track));
                if (chordRest && chordRest->isChord()) {
                    for (mu::engraving::Note* note : mu::engraving::toChord(chordRest)->notes()) {
                        appendNoteOverlayItems(items, note);
                    }
                } else if (chordRest && chordRest->isRest()) {
                    appendRestOverlayItems(items, mu::engraving::toRest(chordRest));
                }
            }
        }
        for (const auto* item : items) {
            crop = crop.united(item->pageBoundingRect());
        }
        const double padding = page->spatium() * 2.0;
        crop.adjust(-padding, -padding, padding, padding);
        crop = crop.intersected(mu::engraving::RectF(0.0, 0.0, page->width(), page->height()));
        mu::engraving::rendering::IScoreRenderer::ScorePaintOptions options;
        options.fromPage = pageIndex;
        options.toPage = pageIndex;
        options.deviceDpi = 144;
        options.printPageBackground = true;
        options.isSetViewport = true;
        options.isMultiPage = false;
        options.isPrinting = true;
        const auto size = m_scoreRenderer()->pageSizeInch(score, options);
        const int width = std::lrint(size.width() * options.deviceDpi);
        const int height = std::lrint(size.height() * options.deviceDpi);
        if (width <= 0 || height <= 0) {
            errorMessage = "The handwriting preview has invalid page dimensions.";
            return false;
        }
        QImage image(width, height, QImage::Format_ARGB32_Premultiplied);
        image.fill(Qt::white);
        muse::draw::Painter painter(&image, "magistris_handwriting_preview");
        m_scoreRenderer()->paintScore(&painter, score, options);
        painter.endDraw();
        const double scaleX = static_cast<double>(width) / page->width();
        const double scaleY = static_cast<double>(height) / page->height();
        const QRect pixelCrop(static_cast<int>(std::floor(crop.left() * scaleX)),
                              static_cast<int>(std::floor(crop.top() * scaleY)),
                              static_cast<int>(std::ceil(crop.width() * scaleX)),
                              static_cast<int>(std::ceil(crop.height() * scaleY)));
        const QImage cropped = image.copy(pixelCrop.intersected(image.rect()));
        QByteArray png;
        QBuffer buffer(&png);
        if (cropped.isNull() || !buffer.open(QIODevice::WriteOnly) || !cropped.save(&buffer, "png")) {
            errorMessage = "The handwriting preview could not be encoded.";
            return false;
        }
        output.pageIndex = pageIndex;
        output.pixelWidth = cropped.width();
        output.pixelHeight = cropped.height();
        output.pngData.assign(png.begin(), png.end());
        return true;
    }
